--[=[
	@module ServiceBuilder
	@within Flite

	ServiceBuilder
	Builds framework services from composable registration APIs.
]=]

local DependencyProxy = require(script.Parent.Parent.Shared.DependencyProxy)
local PersistentBridge = require(script.Parent.PersistentBridge)
local StateRegistration = require(script.Parent.ServiceBuilderModules.StateRegistration)
local SignalRegistration = require(script.Parent.ServiceBuilderModules.SignalRegistration)
local LifecycleRegistration = require(script.Parent.ServiceBuilderModules.LifecycleRegistration)
local PersistenceRegistration = require(script.Parent.ServiceBuilderModules.PersistenceRegistration)
local HookRegistration = require(script.Parent.Parent.Shared.HookRegistration)
local MetadataPublisher = require(script.Parent.ServiceBuilderModules.MetadataPublisher)

local ServiceBuilder = {}

local function hasNetworkSignals(signals: { [string]: any }): boolean
	for _, signal in signals do
		if type(signal) == "table" and typeof(signal._globalEvent) == "Instance" then
			return true
		end
	end
	return false
end

--[=[
	Builds a server service and installs the builder APIs used by service setup code.
	@param globalStateEvent RemoteEvent used for replicated state.
	@param globalSignalEvent RemoteEvent used for reliable signals.
	@param globalUnreliableSignalEvent UnreliableRemoteEvent used for unreliable signals.
	@param name Service name.
	@param getServiceFn Resolves declared service and domain dependencies.
	@param setupFn Configures the service builder context.
	@param options Optional metadata publication settings.
	@return any
]=]
function ServiceBuilder.build(
	globalStateEvent: RemoteEvent,
	globalSignalEvent: RemoteEvent,
	globalUnreliableSignalEvent: UnreliableRemoteEvent,
	name: string,
	getServiceFn: (string) -> any,
	setupFn: (context: any) -> (),
	options: any?
)
	local context = {
		_states = {},
		_signals = {},
		_persistent = nil,
		_onPlayerReady = nil,
		_onPlayerSessionEnd = nil,
		_exposedMethods = {},
		_middlewares = {},
		_dependencies = {},
		_cleanupCallbacks = {},
		_onInit = nil,
		_beforeServerShutdown = nil,
		_onStart = nil,
		_onStop = nil,
		_onPlayerAdded = nil,
		_onPlayerRemoving = nil,
		_onPlayerSpawned = nil,
		_onPlayerDespawned = nil,
		_onHeartbeat = nil,
	}

	local RESERVED_KEYS = {
		Name = true, _serviceFolder = true, _dependencies = true, _fieldDefaults = true,
		_states = true, _signals = true, _persistent = true, _onPlayerReady = true, _onPlayerSessionEnd = true,
		_exposedMethods = true, _middlewares = true, _cleanupCallbacks = true,
		_onInit = true, _beforeServerShutdown = true, _onStart = true, _onStop = true, _onPlayerAdded = true,
		_onPlayerRemoving = true, _onPlayerSpawned = true, _onPlayerDespawned = true, _onHeartbeat = true,
	}
	local BUILDER_API_KEYS = {
		useMapState = true,
		useValueState = true,
		useChannelState = true,
		useComputedState = true,
		useGlobalValue = true,
		useSignal = true,
		useUnreliableSignal = true,
		useGlobalSignal = true,
		usePersistent = true,
		onPlayerReady = true,
		onPlayerSessionEnd = true,
		onInit = true,
		beforeServerShutdown = true,
		onStart = true,
		onStop = true,
		onPlayerAdded = true,
		onPlayerRemoving = true,
		onPlayerSpawned = true,
		onPlayerDespawned = true,
		onHeartbeat = true,
		onHeartbeatFixed = true,
		useMiddleware = true,
		expose = true,
		useDependency = true,
	}

	local function validateFieldName(nameStr: string)
		if RESERVED_KEYS[nameStr] then
			error(`[Framework] Cannot use reserved key '{nameStr}' for state or signal.`)
		end
		if context._states[nameStr] or context._signals[nameStr] then
			error(`[Framework] Namespace collision: '{nameStr}' is already defined in this service.`)
		end
	end

	StateRegistration.bind(context, {
		globalStateEvent = globalStateEvent,
		serviceName = name,
		validateFieldName = validateFieldName,
	})
	SignalRegistration.bind(context, {
		globalSignalEvent = globalSignalEvent,
		globalUnreliableSignalEvent = globalUnreliableSignalEvent,
		serviceName = name,
		validateFieldName = validateFieldName,
	})
	LifecycleRegistration.bind(context)
	PersistenceRegistration.bind(context)
	HookRegistration.bind(context, function(fn)
		table.insert(context._cleanupCallbacks, fn)
	end)

--[=[
	Registers middleware that can approve or reject exposed method calls.
	@param middlewareFn Receives the player, method name, and call arguments.
]=]
	function context:useMiddleware(middlewareFn: (player: Player, methodName: string, ...any) -> boolean)
		table.insert(self._middlewares, middlewareFn)
	end

	--[=[
		Exposes service methods to clients.
		@param nameOrTable Method name or method-name list.
		@param config Optional exposure config.
	]=]
	function context:expose(nameOrTable: string | { string }, config: any?)
		local conf = config or {}
		if type(nameOrTable) == "table" then
			for _, methodName in nameOrTable do
				self._exposedMethods[methodName] = conf
			end
		else
			self._exposedMethods[nameOrTable :: string] = conf
		end
	end

--[=[
	Declares and resolves a dependency on another service.
	@param serviceName serviceName: string
	@return any
]=]
	function context:useDependency(serviceName: string)
		if not table.find(self._dependencies, serviceName) then
			table.insert(self._dependencies, serviceName)
		end

		return DependencyProxy.create(
			serviceName,
			getServiceFn,
			`[Framework] Dependency "{serviceName}" could not be resolved.`
		)
	end

	-- === SERVER ONLY HOOKS ===
--[=[
	Creates a simple per-player rate-limit middleware.
	@param key key: string
	@param limit limit: number
	@param windowMs windowMs: number
	@return (Player) -> boolean
]=]
	function context:useRateLimit(key: string, limit: number, windowMs: number)
		local calls = {}
		return function(player: Player): boolean
			local now = os.clock() * 1000
			calls[player.UserId] = calls[player.UserId] or {}
			table.clear(calls[player.UserId]:filter(function(t) return now - t < windowMs end))
			if #calls[player.UserId] >= limit then
				return false
			end
			table.insert(calls[player.UserId], now)
			return true
		end
	end

--[=[
	Creates a helper that updates player state through a guarded transaction callback.
	@param state state: any
	@return (Player, (any) -> any?) -> ()
]=]
	function context:useTransaction(state: any)
		return function(player: Player, updateFn: (current: any) -> any?)
			local current = state:get(player)
			local ok, newValue = pcall(updateFn, current)
			if ok and newValue ~= nil then
				state:set(player, newValue)
			end
		end
	end

	setupFn(context)

	local service = { Name = name, _serviceFolder = nil }
	service._dependencies = context._dependencies

	for fieldName, state in context._states do
		service[fieldName] = state
	end

	for signalName, signal in context._signals do
		service[signalName] = signal
	end

	for key, value in context do
		if not RESERVED_KEYS[key] and not BUILDER_API_KEYS[key] and context._states[key] == nil and context._signals[key] == nil then
			service[key] = value
		end
	end

	local shouldPublishMetadata = next(context._states) ~= nil
		or next(context._exposedMethods) ~= nil
		or hasNetworkSignals(context._signals)

	if shouldPublishMetadata then
		local serviceFolder = Instance.new("Folder")
		serviceFolder.Name = name
		serviceFolder.Parent = globalStateEvent.Parent
		service._serviceFolder = serviceFolder
		service._fieldDefaults = MetadataPublisher.publish(
			serviceFolder,
			context._states,
			context._signals,
			context._exposedMethods,
			options
		)
	else
		service._fieldDefaults = {}
	end

	service._exposedMethods = context._exposedMethods
	service._middlewares = context._middlewares
	service._cleanupCallbacks = context._cleanupCallbacks

	if context._persistent then
		local disconnect = PersistentBridge.wire(
			service,
			context._persistent,
			context._onPlayerReady,
			context._onPlayerSessionEnd
		)
		if type(disconnect) == "function" then
			table.insert(service._cleanupCallbacks, disconnect)
		end
	end

	service._onInit = context._onInit
	service._beforeServerShutdown = context._beforeServerShutdown
	service._onStart = context._onStart
	service._onStop = context._onStop
	service._onPlayerAdded = context._onPlayerAdded
	service._onPlayerRemoving = context._onPlayerRemoving
	service._onPlayerSpawned = context._onPlayerSpawned
	service._onPlayerDespawned = context._onPlayerDespawned
	service._onHeartbeat = context._onHeartbeat

	return service
end

--[=[
	Runs a service init lifecycle callback when one is registered.
	@param service service: any
]=]
function ServiceBuilder.initialize(service: any)
	if service._onInit then
		service._onInit()
	end
end

--[=[
	Runs a service start lifecycle callback when one is registered.
	@param service service: any
]=]
function ServiceBuilder.finalize(service: any)
	if service._onStart then
		service._onStart()
	end
end

--[=[
	Runs service shutdown callbacks and cleans up owned resources.
	@param service service: any
]=]
function ServiceBuilder.destroy(service: any)
	if type(service._onStop) == "function" then
		local ok, err = pcall(service._onStop)
		if not ok then
			warn(`[Framework] Service onStop failed for {service.Name}: {err}`)
		end
	end

	if service._cleanupCallbacks then
		for _, callback in service._cleanupCallbacks do
			local ok, err = pcall(callback)
			if not ok then
				warn(`[Framework] Service cleanup failed for {service.Name}: {err}`)
			end
		end
		table.clear(service._cleanupCallbacks)
	end

	for key, value in pairs(service) do
		if type(value) == "table" and type(value.destroy) == "function" then
			local ok, err = pcall(function()
				value:destroy()
			end)
			if not ok then
				warn(`[Framework] Service state cleanup failed for {service.Name}.{key}: {err}`)
			end
		end
	end

	if service._serviceFolder and service._serviceFolder.Parent then
		service._serviceFolder:Destroy()
	end
end

return ServiceBuilder
