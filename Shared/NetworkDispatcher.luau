--!optimize 2
--[=[
	@module NetworkDispatcher
	@within Flite

	NetworkDispatcher
	Centralizes identical server-side logic for Buffer payloads and request validation.
	Handles wiring up the global StateEvent, SignalEvent, and MethodEvent routing.
]=]

local BufferCodec = require(script.Parent.BufferCodec)
local RequestValidator = require(script.Parent.RequestValidator)
local FrameworkError = require(script.Parent.FrameworkError)

local NetworkDispatcher = {}
local CONTROL_SERVICE = "__FrameworkControl"
local CONTROL_CANCEL_SIGNAL = "CancelRequest"
local STREAM_SERVICE = "__FrameworkStream"
local STREAM_PROGRESS_SIGNAL = "Progress"
local BUFFER_RETURN_TAG = "__frameworkBufferReturn"

local _signalEvent: RemoteEvent?

local RequestContext = {}
RequestContext.__index = RequestContext

function RequestContext:elapsedMs(): number
	return (os.clock() - self._startedAt) * 1000
end

function RequestContext:remainingMs(): number?
	if not self.timeoutMs then return nil end
	return math.max(0, self.timeoutMs - ((os.clock() - self._startedAt) * 1000))
end

function RequestContext:isTimedOut(): boolean
	if not self.timeoutMs then return false end
	return ((os.clock() - self._startedAt) * 1000) >= self.timeoutMs
end

function RequestContext:isCanceled(): boolean
	if self:isTimedOut() then return true end
	if type(self._tokenId) ~= "string" or #self._tokenId == 0 then return false end
	local bucket = self._cancelledRequests[self.player]
	return bucket and bucket[self._tokenId] == true or false
end

function RequestContext:assertActive(): (boolean, any?)
	if self:isTimedOut() then
		return false, FrameworkError.new(
			FrameworkError.Codes.Timeout,
			`Request timeout in {self.scope}.{self.method}`
		)
	end
	if type(self._tokenId) == "string" and #self._tokenId > 0 then
		local bucket = self._cancelledRequests[self.player]
		if bucket and bucket[self._tokenId] == true then
			bucket[self._tokenId] = nil
			return false, FrameworkError.new(
				FrameworkError.Codes.Canceled,
				`Request canceled in {self.scope}.{self.method}`
			)
		end
	end
	return true, nil
end

function RequestContext:error(code: string, message: string, details: any?)
	return FrameworkError.new(code, message, details)
end

function RequestContext:pushProgress(progressPayload: any)
	if self.metadata == nil or type(self.metadata.requestId) ~= "string" then return end
	if not self:assertActive() then return end
	_signalEvent:FireClient(self.player, STREAM_SERVICE, STREAM_PROGRESS_SIGNAL, self.metadata.requestId, progressPayload)
end

--[=[
	Initializes the global remote event listeners.
	@param services Reference to the server's `services` cache
	@param domains Reference to the shared `domains` cache
	@param FrameworkComm The global networking folder
]=]
function NetworkDispatcher.initialize(services: any, domains: any, FrameworkComm: Folder)
	local Players = game:GetService("Players")
	local stateEvent: RemoteEvent = FrameworkComm:FindFirstChild("StateEvent") :: RemoteEvent
	local signalEvent: RemoteEvent = FrameworkComm:FindFirstChild("SignalEvent") :: RemoteEvent
	_signalEvent = signalEvent
	local unreliableSignalEvent: UnreliableRemoteEvent = FrameworkComm:FindFirstChild("UnreliableSignalEvent") :: UnreliableRemoteEvent
	local methodEvent: RemoteFunction = FrameworkComm:FindFirstChild("MethodEvent") :: RemoteFunction
	local cancelledRequestsByPlayer = {}
	local playerRemovingConnection = Players.PlayerRemoving:Connect(function(player)
		cancelledRequestsByPlayer[player] = nil
	end)

	local function parseInvokeArgs(rawArgs: any)
		local metadata = nil
		local args = rawArgs
		local first = rawArgs[1]
		if type(first) == "table" and first.__frameworkMeta == true then
			metadata = first
			local packed = table.pack()
			for i = 2, rawArgs.n do
				packed[#packed + 1] = rawArgs[i]
			end
			packed.n = rawArgs.n - 1
			args = packed
		end
		return metadata, args
	end
	
	local function isPureSchema(argsFormat)
		if type(argsFormat) ~= "table" or #argsFormat == 0 then return false end
		for _, v in ipairs(argsFormat) do
			if type(v) ~= "table" or type(v.validate) ~= "function" or not v.unpack or not v.pack or not v.getSize then
				return false
			end
		end
		return true
	end

	local function getReturnSchemas(config: any): any
		if type(config) ~= "table" then
			return nil
		end
		if type(config.returns) == "table" then
			return config.returns
		end
		if type(config.contract) == "table" and type(config.contract.returns) == "table" then
			return config.contract.returns
		end
		return nil
	end

	local function encodeBufferedReturn(config: any, ...: any): any?
		local returnSchemas = getReturnSchemas(config)
		if not isPureSchema(returnSchemas) then
			return nil
		end

		local values = table.pack(...)
		local ok, buf, inst = pcall(BufferCodec.serialize, returnSchemas, table.unpack(values, 1, values.n))
		if not ok then
			return nil
		end

		return {
			[BUFFER_RETURN_TAG] = true,
			buf = buf,
			inst = inst or {},
		}
	end

	-- Helper to intercept buffer payloads, deserialize them, and validate
	local function decodeAndValidate(
		player: Player,
		config: any,
		args: any,
		serviceName: string,
		service: any,
		entryName: string,
		metadata: any?,
		requestContext: any?
	): (boolean, any, any?)
		local safeConfig = if type(config) == "table" then config else {}
		local argsSchema = safeConfig.args
		if argsSchema == nil and type(safeConfig.contract) == "table" then
			argsSchema = safeConfig.contract.args
		end

		if type(args[1]) == "buffer" and isPureSchema(argsSchema) then
			local success, result = pcall(BufferCodec.deserialize, argsSchema, args[1], args[2] or {})
			if not success then
				return false, args, FrameworkError.new(
					FrameworkError.Codes.ValidationError,
					`failed to decode buffer for {serviceName}.{entryName}`
				)
			end
			args = result
		end
		
		local isValid, validationError = RequestValidator.validate(
			player,
			serviceName,
			service,
			entryName,
			safeConfig,
			metadata,
			requestContext,
			table.unpack(args, 1, args.n)
		)
		return isValid, args, validationError
	end

	local stateConnection = stateEvent.OnServerEvent:Connect(function(player, serviceName, fieldName)
		local service = services[serviceName]
		if service and service[fieldName] and type(service[fieldName].get) == "function" then
			stateEvent:FireClient(player, serviceName, fieldName, service[fieldName]:get(player))
		end
	end)

	-- Handler for both reliable and unreliable network signals
	local function handleSignalEvent(player, serviceName, signalName, ...)
		if serviceName == CONTROL_SERVICE and signalName == CONTROL_CANCEL_SIGNAL then
			local tokenId = ...
			if type(tokenId) == "string" and #tokenId > 0 then
				local bucket = cancelledRequestsByPlayer[player]
				if not bucket then
					bucket = {}
					cancelledRequestsByPlayer[player] = bucket
				end
				bucket[tokenId] = true
			end
			return
		end

		local service = services[serviceName]
		if service and service[signalName] and type(service[signalName].fire) == "function" then
			-- Security: only explicitly exposed signals can be fired by clients
			local config = service._exposedMethods and service._exposedMethods[signalName]
			if not config then
				warn(`[Framework] Client attempted to fire unexposed signal '{signalName}' on {serviceName}`)
				return
			end

			-- If no args schema was configured in expose(), fall back to signal schema metadata
			if config.args == nil and service[signalName]._schema ~= nil then
				config = {
					rateLimit = config.rateLimit,
					onSpam = config.onSpam,
					middleware = config.middleware,
					args = service[signalName]._schema,
				}
			end
			
			local args = table.pack(...)
			local isValid, decodedArgs = decodeAndValidate(player, config, args, serviceName, service, signalName, nil, nil)
			if not isValid then return end
			
			-- Fire the server-side local signal with the player + args
			service[signalName]:fire(player, table.unpack(decodedArgs, 1, decodedArgs.n))
		else
			warn(`[Framework] Client attempted to fire unknown signal '{signalName}' on {serviceName}`)
		end
	end

	-- When a client fires a SignalEvent, route it to the correct local framework signal.
	local signalConnection = signalEvent.OnServerEvent:Connect(handleSignalEvent)
	local unreliableSignalConnection = unreliableSignalEvent.OnServerEvent:Connect(handleSignalEvent)

	-- When a client invokes MethodEvent, route to the correct exposed method across Domains/Services.
	-- Roblox treats OnServerInvoke as write-only, so we must never read it here.
	methodEvent.OnServerInvoke = function(player, serviceName, methodName, ...)
		local rawArgs = table.pack(...)
		local metadata, args = parseInvokeArgs(rawArgs)
		local tokenId = metadata and metadata.cancelTokenId
		if type(tokenId) == "string" and #tokenId > 0 then
			local bucket = cancelledRequestsByPlayer[player]
			if bucket and bucket[tokenId] == true then
				bucket[tokenId] = nil
				return nil, FrameworkError.new(FrameworkError.Codes.Canceled, "Request canceled")
			end
		end

		local function createRequestContext(scopeName: string)
			local timeoutMs = nil
			if metadata and type(metadata.timeoutMs) == "number" then
				timeoutMs = math.clamp(metadata.timeoutMs, 1, 120000)
			end
			return setmetatable({
				player = player,
				scope = scopeName,
				method = methodName,
				metadata = metadata,
				timeoutMs = timeoutMs,
				_startedAt = os.clock(),
				_tokenId = tokenId,
				_cancelledRequests = cancelledRequestsByPlayer,
			}, RequestContext)
		end
		
		-- Check if it's a domain call first
		if string.sub(serviceName, -7) == "_Domain" then
			local trueDomainName = string.sub(serviceName, 1, -8)
			local domain = domains[trueDomainName]
			if domain then
				local fn = domain[methodName]
				if type(fn) == "function" then
					local config = domain._exposedMethods[methodName] or {}
					local requestContext = createRequestContext(trueDomainName)
					local activeOk, activeErr = requestContext:assertActive()
					if not activeOk then
						return nil, activeErr
					end
					local isValid, decodedArgs, validationError = decodeAndValidate(
						player,
						config,
						args,
						trueDomainName,
						domain,
						methodName,
						metadata,
						requestContext
					)
					if not isValid then
						return nil, validationError
					end
					local results = table.pack(
						pcall(fn, domain, player, table.unpack(decodedArgs, 1, decodedArgs.n), requestContext)
					)
					if not results[1] then
						warn(`[Framework] Server Error in Domain {trueDomainName}.{methodName} invoked by {player.Name}: {results[2]}`)
						return nil, FrameworkError.new(
							FrameworkError.Codes.ServerError,
							`Domain {trueDomainName}.{methodName} failed`,
							{ raw = results[2] }
						)
					end
					if not RequestValidator.validateReturns(trueDomainName, methodName, config, table.unpack(results, 2, results.n)) then
						return nil, FrameworkError.new(
							FrameworkError.Codes.ValidationError,
							`invalid return payload from {trueDomainName}.{methodName}`
						)
					end
					local stillActive, activeErrAfter = requestContext:assertActive()
					if not stillActive then
						return nil, activeErrAfter
					end
					local bufferedReturn = encodeBufferedReturn(config, table.unpack(results, 2, results.n))
					if bufferedReturn ~= nil then
						return bufferedReturn
					end
					return table.unpack(results, 2, results.n)
				end
			end
			return nil, FrameworkError.new(FrameworkError.Codes.DomainNotFound, `Domain "{trueDomainName}" not found`)
		end
		
		-- Otherwise route to Service call
		local service = services[serviceName]
		if service then
			local config = service._exposedMethods[methodName]
			if config then
				local fn = service[methodName]
				if type(fn) == "function" then
					local requestContext = createRequestContext(serviceName)
					local activeOk, activeErr = requestContext:assertActive()
					if not activeOk then
						return nil, activeErr
					end
					local isValid, decodedArgs, validationError = decodeAndValidate(
						player,
						config,
						args,
						serviceName,
						service,
						methodName,
						metadata,
						requestContext
					)
					if not isValid then
						return nil, validationError
					end
					local results = table.pack(
						pcall(fn, service, player, table.unpack(decodedArgs, 1, decodedArgs.n), requestContext)
					)
					if not results[1] then
						warn(`[Framework] Server Error in Service {serviceName}.{methodName} invoked by {player.Name}: {results[2]}`)
						return nil, FrameworkError.new(
							FrameworkError.Codes.ServerError,
							`Service {serviceName}.{methodName} failed`,
							{ raw = results[2] }
						)
					end
					if not RequestValidator.validateReturns(serviceName, methodName, config, table.unpack(results, 2, results.n)) then
						return nil, FrameworkError.new(
							FrameworkError.Codes.ValidationError,
							`invalid return payload from {serviceName}.{methodName}`
						)
					end
					local stillActive, activeErrAfter = requestContext:assertActive()
					if not stillActive then
						return nil, activeErrAfter
					end
					local bufferedReturn = encodeBufferedReturn(config, table.unpack(results, 2, results.n))
					if bufferedReturn ~= nil then
						return bufferedReturn
					end
					return table.unpack(results, 2, results.n)
				end
				return nil, FrameworkError.new(
					FrameworkError.Codes.MethodNotFound,
					`Method "{methodName}" is not implemented on {serviceName}`
				)
			else
				warn(`[Framework] Client attempted to invoke unexposed method '{methodName}' on {serviceName}`)
				return nil, FrameworkError.new(
					FrameworkError.Codes.PermissionDenied,
					`Method "{methodName}" is not exposed on {serviceName}`
				)
			end
		end
		return nil, FrameworkError.new(FrameworkError.Codes.ServiceNotFound, `Service "{serviceName}" not found`)
	end

	return function()
		stateConnection:Disconnect()
		signalConnection:Disconnect()
		unreliableSignalConnection:Disconnect()
		methodEvent.OnServerInvoke = nil
		playerRemovingConnection:Disconnect()
		table.clear(cancelledRequestsByPlayer)
	end
end

return NetworkDispatcher
