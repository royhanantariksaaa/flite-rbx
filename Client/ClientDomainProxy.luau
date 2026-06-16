--[[
	ClientDomainProxy
	Client wrapper for shared Domain methods with optimistic local prediction.
]]

local Promise = require(game:GetService("ReplicatedStorage").Libraries.Promise)
local HttpService = game:GetService("HttpService")
local BufferCodec = require(script.Parent.Parent.Shared.BufferCodec)
local FrameworkError = require(script.Parent.Parent.Shared.FrameworkError)
local t = require(script.Parent.Parent.Shared.t)
local ServiceProxy = require(script.Parent.ServiceProxy)
local DomainBus = require(script.Parent.Parent.Shared.DomainBus)

local ClientDomainProxy = {}
local CONTROL_SERVICE = "__FrameworkControl"
local CONTROL_CANCEL_SIGNAL = "CancelRequest"
local DEFAULT_REQUEST_TIMEOUT_SECONDS = 15
local BUFFER_RETURN_TAG = "__frameworkBufferReturn"

local function isBufferReturnPacket(value: any): boolean
	return type(value) == "table"
		and value[BUFFER_RETURN_TAG] == true
		and type(value.buf) == "buffer"
		and type(value.inst) == "table"
end

local function isPureSchema(argsFormat)
	if type(argsFormat) ~= "table" or #argsFormat == 0 then
		return false
	end
	for _, v in ipairs(argsFormat) do
		if type(v) ~= "table" or type(v.validate) ~= "function" or not v.unpack or not v.pack or not v.getSize then
			return false
		end
	end
	return true
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

local function readStateValue(value: any)
	if type(value) ~= "table" then
		return nil
	end

	if type(value.get) == "function" then
		return function()
			return value:get()
		end
	end

	if type(value.Get) == "function" then
		return function()
			return value:Get()
		end
	end

	return nil
end

local function writeStateValue(value: any)
	if type(value) ~= "table" then
		return nil
	end

	if type(value.set) == "function" then
		return function(newValue)
			value:set(newValue)
		end
	end

	if type(value.Set) == "function" then
		return function(newValue)
			value:Set(newValue)
		end
	end

	return nil
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

function ClientDomainProxy.new(
	domainName: string,
	domainDef: any,
	methodEvent: RemoteFunction,
	signalEvent: RemoteEvent?,
	getLocalService: (string) -> any,
	getLocalDomain: (string) -> any
)
	local proxy = {}
	local isRollingBack = false

	local function makeMockSystem(rollbacks: { any })
		local mockSystem = {}
		setmetatable(mockSystem, {
			__index = function(_, dependencyName)
				if dependencyName == "emit" then
					return function(eventName: string, payload: any?)
						DomainBus.emit(domainName, eventName, payload)
					end
				end
				if dependencyName == "on" then
					return function(eventName: string, callback: (any?) -> ())
						return DomainBus.on(domainName, eventName, callback)
					end
				end

				local localSvc = getLocalService(dependencyName)
				if localSvc then
					local wrappedSvc = {}
					setmetatable(wrappedSvc, {
						__index = function(_, key)
							local value = localSvc[key]
							local readValue = readStateValue(value)
							local writeValue = writeStateValue(value)
							if readValue and writeValue then
								local wrappedValue = {}
								wrappedValue.set = function(_, newValue)
									table.insert(rollbacks, {
										state = value,
										original = readValue(),
									})
									writeValue(newValue)
								end
								wrappedValue.get = function()
									return readValue()
								end
								wrappedValue.Set = wrappedValue.set
								wrappedValue.Get = wrappedValue.get
								setmetatable(wrappedValue, {
									__index = value,
									__newindex = value,
								})
								return wrappedValue
							end
							return value
						end,
					})
					return wrappedSvc
				end

				local localDomain = getLocalDomain(dependencyName)
				if localDomain then
					return localDomain
				end

				error(
					`[Framework] Domain "{domainName}" tried to resolve "{dependencyName}" on client, but it was unavailable.`
				)
			end,
		})
		return mockSystem
	end

	local function rollbackSnapshots(rollbacks: { any })
		if #rollbacks == 0 then
			return
		end
		isRollingBack = true
		for i = #rollbacks, 1, -1 do
			local snapshot = rollbacks[i]
			local writeValue = writeStateValue(snapshot.state)
			if writeValue then
				writeValue(snapshot.original)
			end
		end
		isRollingBack = false
	end

	function proxy:emit(eventName: string, payload: any?)
		DomainBus.emit(domainName, eventName, payload)
	end

	function proxy:on(eventName: string, callback: (any?) -> ())
		return DomainBus.on(domainName, eventName, callback)
	end

	for methodName, data in domainDef._exposedMethods do
		proxy[methodName] = function(_, ...)
			if isRollingBack then
				return Promise.resolve(nil)
			end

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

			local localPlayer = game:GetService("Players").LocalPlayer
			local rollbacks = {}
			local requestId = HttpService:GenerateGUID(false)
			local metadata = {
				__frameworkMeta = true,
				requestId = requestId,
				timeoutMs = DEFAULT_REQUEST_TIMEOUT_SECONDS * 1000,
			}
			if cancelToken then
				metadata.cancelTokenId = cancelToken.id
			end

			local predictionSuccess, predictionResult = pcall(function()
				local mockSystem = makeMockSystem(rollbacks)
				return data.fn(mockSystem, localPlayer, table.unpack(args, 1, args.n))
			end)
			if not predictionSuccess then
				rollbackSnapshots(rollbacks)
				return Promise.reject(
					`[Framework] Domain prediction failed for {domainName}.{methodName}: {predictionResult}`
				)
			end

			local detachedCancelListener = nil
			if cancelToken then
				detachedCancelListener = cancelToken:onCancel(function()
					if signalEvent then
						signalEvent:FireServer(CONTROL_SERVICE, CONTROL_CANCEL_SIGNAL, cancelToken.id)
					end
				end)
			end

			local progressCallbacks = {}
			local detachProgress = ServiceProxy.registerStreamObserver(requestId, function(payload)
				for _, callback in ipairs(progressCallbacks) do
					callback(payload)
				end
			end)

			local authoritative = Promise.try(function()
				local schemas
				if data.config and type(data.config) == "table" and type(data.config.args) == "table" then
					schemas = data.config.args
				end

				if schemas then
					local ok, buf, instArray = pcall(BufferCodec.serialize, schemas, table.unpack(args, 1, args.n))
					if ok then
						return methodEvent:InvokeServer(domainName .. "_Domain", methodName, metadata, buf, instArray)
					end
				end

				return methodEvent:InvokeServer(
					domainName .. "_Domain",
					methodName,
					metadata,
					table.unpack(args, 1, args.n)
				)
			end):timeout(DEFAULT_REQUEST_TIMEOUT_SECONDS):finally(function()
				detachProgress()
				if detachedCancelListener then
					detachedCancelListener()
				end
			end)

			local withProgressPromise = withProgress(authoritative, function(callback)
				table.insert(progressCallbacks, callback)
			end)

			return withProgressPromise:andThen(function(...)
				local results = table.pack(...)
				if results.n == 1 and FrameworkError.isError(results[1]) then
					return Promise.reject(results[1])
				end
				if results.n >= 2 and results[1] == nil and FrameworkError.isError(results[2]) then
					return Promise.reject(results[2])
				end

				if results.n == 1 and isBufferReturnPacket(results[1]) then
					local returnSchemas = nil
					local config = data.config
					if type(config) == "table" and type(config.returns) == "table" then
						if isPureSchema(config.returns) then
							returnSchemas = config.returns
						else
							local hydrated = hydrateSchemas(config.returns)
							if hydrated and isPureSchema(hydrated) then
								config.returns = hydrated
								returnSchemas = hydrated
							end
						end
					end

					if returnSchemas then
						local packet = results[1]
						local ok, decoded = pcall(BufferCodec.deserialize, returnSchemas, packet.buf, packet.inst)
						if not ok then
							return Promise.reject(FrameworkError.new(
								FrameworkError.Codes.ValidationError,
								`failed to decode return payload for {domainName}.{methodName}`
							))
						end
						return table.unpack(decoded, 1, decoded.n)
					end
				end
				return ...
			end):catch(function(err)
				rollbackSnapshots(rollbacks)
				error(err)
			end)
		end
	end

	return proxy
end

return ClientDomainProxy
