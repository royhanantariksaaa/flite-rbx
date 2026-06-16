--[[
	ServiceProxy
	Client-side proxy returned by scope:useService().
]]

local ClientSignalProxy = require(script.Parent.ClientSignalProxy)
local BufferCodec = require(script.Parent.Parent.Shared.BufferCodec)
local t = require(script.Parent.Parent.Shared.t)
local FrameworkError = require(script.Parent.Parent.Shared.FrameworkError)
local Promise = require(game:GetService("ReplicatedStorage").Libraries.Promise)
local HttpService = game:GetService("HttpService")

local ServiceProxy = {}
local CONTROL_SERVICE = "__FrameworkControl"
local CONTROL_CANCEL_SIGNAL = "CancelRequest"
local STREAM_PROGRESS_OBSERVERS = {}
local DEFAULT_REQUEST_TIMEOUT_SECONDS = 15
local BUFFER_RETURN_TAG = "__frameworkBufferReturn"

local function isBufferReturnPacket(value: any): boolean
	return type(value) == "table"
		and value[BUFFER_RETURN_TAG] == true
		and type(value.buf) == "buffer"
		and type(value.inst) == "table"
end

local function hydrateSchemas(typeDefs: { any }): { any }?
	local reconstructed = {}
	for i, def in ipairs(typeDefs) do
		local schema = t.load(def)
		if not schema then
			return nil
		end
		reconstructed[i] = schema
	end
	return reconstructed
end

local function isCancelToken(value: any): boolean
	return type(value) == "table"
		and type(value.id) == "string"
		and type(value.cancel) == "function"
		and type(value.isCancelled) == "function"
end

local function withProgress(promiseObj: any, attachFn: (callback: (any) -> ()) -> ())
	local assigned = pcall(function()
		promiseObj.onProgress = function(_, callback)
			if type(callback) == "function" then
				attachFn(callback)
			end
			return promiseObj
		end
	end)

	if assigned then
		return promiseObj
	end

	local wrapper = {}
	function wrapper:onProgress(callback)
		if type(callback) == "function" then
			attachFn(callback)
		end
		return self
	end

	setmetatable(wrapper, {
		__index = function(_, key)
			local value = promiseObj[key]
			if type(value) == "function" then
				return function(_, ...)
					return value(promiseObj, ...)
				end
			end
			return value
		end,
	})

	return wrapper
end

function ServiceProxy.dispatchStreamProgress(requestId: string, payload: any)
	local observers = STREAM_PROGRESS_OBSERVERS[requestId]
	if not observers then
		return
	end

	for _, callback in ipairs(observers) do
		callback(payload)
	end
end

function ServiceProxy.registerStreamObserver(requestId: string, callback: (any) -> ())
	local observers = STREAM_PROGRESS_OBSERVERS[requestId]
	if not observers then
		observers = {}
		STREAM_PROGRESS_OBSERVERS[requestId] = observers
	end
	table.insert(observers, callback)

	return function()
		for i, fn in ipairs(observers) do
			if fn == callback then
				table.remove(observers, i)
				break
			end
		end
		if #observers == 0 then
			STREAM_PROGRESS_OBSERVERS[requestId] = nil
		end
	end
end

function ServiceProxy.new(
	scope: any,
	serviceName: string,
	serviceFolder: Folder,
	fieldDefaults: { [string]: any },
	stateFields: { string },
	signalNames: { string },
	unreliableSignals: { [string]: boolean },
	methodNames: { string },
	stateEvent: RemoteEvent,
	signalEvent: RemoteEvent,
	unreliableSignalEvent: UnreliableRemoteEvent,
	methodEvent: RemoteFunction,
	signalSchemaDefs: { [string]: { any } }?,
	methodSchemaDefs: { [string]: { any } }?,
	methodReturnSchemaDefs: { [string]: { any } }?
)
	local proxy = {}
	local fieldsToRequest = {}

	local seenStateFields = {}
	for _, fieldName in stateFields do
		seenStateFields[fieldName] = true
		local value = scope.Value(fieldDefaults[fieldName])
		proxy[fieldName] = value
		table.insert(fieldsToRequest, fieldName)
	end

	for fieldName, defaultValue in fieldDefaults do
		if not seenStateFields[fieldName] then
			local value = scope.Value(defaultValue)
			proxy[fieldName] = value
			table.insert(fieldsToRequest, fieldName)
		end
	end

	local signalSchemasMap = {}
	local parsedSignalSchemas = signalSchemaDefs
	if parsedSignalSchemas == nil then
		local encodedSignalSchemas = serviceFolder:GetAttribute("_signalSchemas")
		if encodedSignalSchemas then
			parsedSignalSchemas = HttpService:JSONDecode(encodedSignalSchemas)
		end
	end
	if parsedSignalSchemas then
		local parsed = parsedSignalSchemas
		for signalName, typeDefs in pairs(parsed) do
			local reconstructed = {}
			local isComplete = true
			for i, def in ipairs(typeDefs) do
				local schema = t.load(def)
				if schema then
					reconstructed[i] = schema
				else
					isComplete = false
					break
				end
			end
			if isComplete then
				signalSchemasMap[signalName] = reconstructed
			end
		end
	end

	for _, signalName in signalNames do
		proxy[signalName] = ClientSignalProxy.new(
			unreliableSignals[signalName] and unreliableSignalEvent or signalEvent,
			serviceName,
			signalName,
			signalSchemasMap[signalName]
		)
	end

	local knownMethods = {}
	for _, methodName in methodNames do
		knownMethods[methodName] = true
	end

	local rawMethodSchemas = {}
	local resolvedMethodSchemas = {}
	local rawMethodReturnSchemas = {}
	local resolvedMethodReturnSchemas = {}
	local parsedMethodSchemas = methodSchemaDefs
	if parsedMethodSchemas == nil then
		local encodedSchemas = serviceFolder:GetAttribute("_methodSchemas")
		if encodedSchemas then
			parsedMethodSchemas = HttpService:JSONDecode(encodedSchemas)
		end
	end
	if parsedMethodSchemas then
		local parsed = parsedMethodSchemas
		for methodName, typeDefs in pairs(parsed) do
			knownMethods[methodName] = true
			rawMethodSchemas[methodName] = typeDefs
		end
	end

	local parsedMethodReturnSchemas = methodReturnSchemaDefs
	if parsedMethodReturnSchemas == nil then
		local encodedReturnSchemas = serviceFolder:GetAttribute("_methodReturnSchemas")
		if encodedReturnSchemas then
			parsedMethodReturnSchemas = HttpService:JSONDecode(encodedReturnSchemas)
		end
	end
	if parsedMethodReturnSchemas then
		for methodName, typeDefs in pairs(parsedMethodReturnSchemas) do
			knownMethods[methodName] = true
			rawMethodReturnSchemas[methodName] = typeDefs
		end
	end

	setmetatable(proxy, {
		__index = function(_, methodName)
			if not knownMethods[methodName] and string.sub(methodName, 1, 1) ~= "_" then
				warn(`[Framework] ServiceProxy "{serviceName}": unknown field "{methodName}" (possible typo)`)
			end

			local wrapped = function(_, ...)
				local args = table.pack(...)
				local cancelToken = nil
				if args.n > 0 and isCancelToken(args[args.n]) then
					cancelToken = args[args.n]
					args[args.n] = nil
					args.n -= 1
				end

				if cancelToken and cancelToken:isCancelled() then
					return Promise.reject(cancelToken:getReason() or "RequestCanceled")
				end

				local requestId = HttpService:GenerateGUID(false)
				local metadata = {
					__frameworkMeta = true,
					requestId = requestId,
					timeoutMs = DEFAULT_REQUEST_TIMEOUT_SECONDS * 1000,
				}
				if cancelToken then
					metadata.cancelTokenId = cancelToken.id
				end

				local progressObservers = {}
				STREAM_PROGRESS_OBSERVERS[requestId] = progressObservers

				local detachedCancelListener = nil
				if cancelToken then
					detachedCancelListener = cancelToken:onCancel(function()
						signalEvent:FireServer(CONTROL_SERVICE, CONTROL_CANCEL_SIGNAL, cancelToken.id)
					end)
				end

				local promiseObj = Promise.new(function(resolve, reject)
					local ok, resultOrError = pcall(function()
						local schemas = resolvedMethodSchemas[methodName]
						if schemas == nil then
							local typeDefs = rawMethodSchemas[methodName]
							if typeDefs then
								local reconstructed = {}
								local isComplete = true
								for i, def in ipairs(typeDefs) do
									local schema = t.load(def)
									if schema then
										reconstructed[i] = schema
									else
										warn(`[Framework] Unknown schema definition for {serviceName}.{methodName}. Falling back to uncompressed packets.`)
										isComplete = false
										break
									end
								end

								schemas = if isComplete then reconstructed else false
								resolvedMethodSchemas[methodName] = schemas
							end
						end

						if schemas and schemas ~= false then
							local schemaDefs = schemas :: { any }
							local buf, instArray = BufferCodec.serialize(schemaDefs, table.unpack(args, 1, args.n))
							return table.pack(methodEvent:InvokeServer(serviceName, methodName, metadata, buf, instArray))
						end

						return table.pack(
							methodEvent:InvokeServer(serviceName, methodName, metadata, table.unpack(args, 1, args.n))
						)
					end)

					if not ok then
						reject(resultOrError)
						return
					end

					if resultOrError.n == 1 and FrameworkError.isError(resultOrError[1]) then
						reject(resultOrError[1])
						return
					end
					if resultOrError.n >= 2 and resultOrError[1] == nil and FrameworkError.isError(resultOrError[2]) then
						reject(resultOrError[2])
						return
					end

					if resultOrError.n == 1 and isBufferReturnPacket(resultOrError[1]) then
						local schemas = resolvedMethodReturnSchemas[methodName]
						if schemas == nil then
							local typeDefs = rawMethodReturnSchemas[methodName]
							if typeDefs then
								local hydrated = hydrateSchemas(typeDefs)
								schemas = hydrated or false
								resolvedMethodReturnSchemas[methodName] = schemas
							end
						end

						if schemas and schemas ~= false then
							local packet = resultOrError[1]
							local ok, decoded = pcall(BufferCodec.deserialize, schemas, packet.buf, packet.inst)
							if ok then
								resultOrError = decoded
							else
								reject(FrameworkError.new(
									FrameworkError.Codes.ValidationError,
									`failed to decode return payload for {serviceName}.{methodName}`
								))
								return
							end
						end
					end

					if cancelToken and cancelToken:isCancelled() then
						reject(cancelToken:getReason() or "RequestCanceled")
						return
					end

					resolve(table.unpack(resultOrError, 1, resultOrError.n))
				end):timeout(DEFAULT_REQUEST_TIMEOUT_SECONDS):finally(function()
					STREAM_PROGRESS_OBSERVERS[requestId] = nil
					if detachedCancelListener then
						detachedCancelListener()
					end
				end)

				return withProgress(promiseObj, function(callback)
					table.insert(progressObservers, callback)
				end)
			end

			rawset(proxy, methodName, wrapped)
			return wrapped
		end,
	})

	function proxy:_requestInitialValues()
		for _, fieldName in fieldsToRequest do
			stateEvent:FireServer(serviceName, fieldName)
		end
		table.clear(fieldsToRequest)
	end

	return proxy
end

return ServiceProxy
