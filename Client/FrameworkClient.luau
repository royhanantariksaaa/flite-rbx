--[=[
	@module FrameworkClient
	@within Flite

	FrameworkClient
	Handles Client-side controller creation, domain proxying, and lifecycle bootstrapping.
]=]

local RunService = game:GetService("RunService")
local HttpService = game:GetService("HttpService")
local Weave = require(game:GetService("ReplicatedStorage").Libraries.Weave)
local ControllerBuilder = require(script.Parent.ControllerBuilder)
local ServiceProxy = require(script.Parent.ServiceProxy)
local ClientDomainProxy = require(script.Parent.ClientDomainProxy)
local DependencySorter = require(script.Parent.Parent.Shared.DependencySorter)

local FrameworkClient = {}
local makeFrameDispatcher: ((any) -> ((number) -> ())?)
type StartOptions = {
	deferLifecycle: boolean?,
	parallelInit: boolean?,
	manifestOnly: boolean?,
	parallelInitMinCount: number?,
}
local COMM_REMOTES_CACHE = setmetatable({}, { __mode = "k" })
local RESERVED_SERVICE_ATTRIBUTES = {
	_signals = true,
	_unreliableSignals = true,
	_methods = true,
	_methodSchemas = true,
	_methodReturnSchemas = true,
	_signalSchemas = true,
	_stateFields = true,
	_fieldDefaults = true,
	_manifest = true,
}

local function decodeJsonAttribute(folder: Instance, attributeName: string): any?
	local encoded = folder:GetAttribute(attributeName)
	if type(encoded) ~= "string" then
		return nil
	end

	local ok, decoded = pcall(function()
		return HttpService:JSONDecode(encoded)
	end)
	if ok then
		return decoded
	end

	return nil
end

local function getFrameworkCommRemotes(FrameworkComm: Folder)
	local cached = COMM_REMOTES_CACHE[FrameworkComm]
	if cached then
		return cached
	end

	local remotes = {
		stateEvent = FrameworkComm:WaitForChild("StateEvent", 10) :: any,
		signalEvent = FrameworkComm:WaitForChild("SignalEvent", 10) :: any,
		unreliableSignalEvent = FrameworkComm:WaitForChild("UnreliableSignalEvent", 10) :: any,
		methodEvent = FrameworkComm:WaitForChild("MethodEvent", 10) :: any,
	}

	COMM_REMOTES_CACHE[FrameworkComm] = remotes
	return remotes
end

local function decodeFieldDefaults(serviceFolder: Folder): { [string]: any }
	local encodedFieldDefaults = decodeJsonAttribute(serviceFolder, "_fieldDefaults")
	if type(encodedFieldDefaults) == "table" then
		return encodedFieldDefaults
	end

	local fieldDefaults = {}
	for attrName, attrValue in serviceFolder:GetAttributes() do
		if not RESERVED_SERVICE_ATTRIBUTES[attrName] then
			if type(attrValue) == "string" and string.sub(attrValue, 1, 4) == "JSN:" then
				local success, decoded = pcall(function()
					return HttpService:JSONDecode(string.sub(attrValue, 5))
				end)
				fieldDefaults[attrName] = if success then decoded else attrValue
			else
				fieldDefaults[attrName] = attrValue
			end
		end
	end

	return fieldDefaults
end

local function decodeServiceManifest(serviceFolder: Folder): any?
	local manifest = decodeJsonAttribute(serviceFolder, "_manifest")
	if type(manifest) == "table" then
		return manifest
	end
	return nil
end

--[=[
	Creates and registers a client controller from a setup callback.
	@param name Controller name.
	@param setupFn Configures the controller object.
	@param controllers Controller registry table.
	@param services Service proxy registry table.
	@param domains Domain proxy registry table.
	@param FrameworkComm Replicated framework communication folder.
	@return any
]=]
function FrameworkClient.createController(name: string, setupFn: (controller: any) -> (), controllers: any, services: any, domains: any, FrameworkComm: Folder)
	local controller = ControllerBuilder.build(name, function(dependencyName)
		assert(controllers[dependencyName], `[Framework] Controller "{dependencyName}" not found`)
		return controllers[dependencyName]
	end, function(serviceName)
		return FrameworkClient.getService(serviceName, services, FrameworkComm)
	end, function(domainName)
		return FrameworkClient.getDomain(domainName, domains, FrameworkComm, services)
	end, setupFn)
	controllers[name] = controller
	return controller
end

--[=[
	Returns a cached client service proxy, creating it from replicated metadata when needed.
	@param name name: string
	@param services services: any
	@param FrameworkComm FrameworkComm: Folder
	@return any
]=]
function FrameworkClient.getService(name: string, services: any, FrameworkComm: Folder)
	if not services[name] then
		local serviceFolder = FrameworkComm:FindFirstChild(name) or FrameworkComm:WaitForChild(name, 10)
		if not serviceFolder then
			error(`[Framework] Service "{name}" not found on server or taking too long to replicate.`)
		end

		local remotes = getFrameworkCommRemotes(FrameworkComm)
		local manifest = decodeServiceManifest(serviceFolder)
		local manifestOnly = FrameworkComm:GetAttribute("_manifestOnly") == true
		if manifestOnly and manifest == nil then
			error(`[Framework] Service "{name}" is missing required _manifest metadata while manifestOnly mode is enabled.`)
		end
		local fieldDefaults = if manifest and type(manifest.fieldDefaults) == "table" then manifest.fieldDefaults else decodeFieldDefaults(serviceFolder)
		local stateFields = {}
		local decodedStateFields = if manifest then manifest.stateFields else decodeJsonAttribute(serviceFolder, "_stateFields")
		if type(decodedStateFields) == "table" then
			stateFields = decodedStateFields
		end

		-- Reconstruct signalNames from Attributes
		local signalNames = {}
		local decodedSignals = if manifest then manifest.signals else decodeJsonAttribute(serviceFolder, "_signals")
		if type(decodedSignals) == "table" then
			signalNames = decodedSignals
		end

		local unreliableSignals = {}
		local decodedUnreliableSignals = if manifest then manifest.unreliableSignals else decodeJsonAttribute(serviceFolder, "_unreliableSignals")
		if type(decodedUnreliableSignals) == "table" then
			for _, v in decodedUnreliableSignals do
				unreliableSignals[v] = true
			end
		end

		local methodNames = {}
		local decodedMethods = if manifest then manifest.methods else decodeJsonAttribute(serviceFolder, "_methods")
		if type(decodedMethods) == "table" then
			methodNames = decodedMethods
		end

		local scope = Weave.Scope()
		local proxy = ServiceProxy.new(
			scope,
			name,
			serviceFolder,
			fieldDefaults,
			stateFields,
			signalNames,
			unreliableSignals,
			methodNames,
			remotes.stateEvent,
			remotes.signalEvent,
			remotes.unreliableSignalEvent,
			remotes.methodEvent,
			if manifest then manifest.signalSchemas else nil,
			if manifest then manifest.methodSchemas else nil,
			if manifest then manifest.methodReturnSchemas else nil
		)

		-- Register the proxy FIRST so the central listener can route responses
		services[name] = proxy

		-- NOW request initial values (after proxy is in the services cache)
		-- This prevents race conditions where responses arrive before the proxy is registered
		proxy:_requestInitialValues()
	end
	return services[name]
end

--[=[
	Returns a cached client domain proxy, creating it from replicated metadata when needed.
	@param name name: string
	@param domains domains: any
	@param FrameworkComm FrameworkComm: Folder
	@param services services: any
	@return any
]=]
function FrameworkClient.getDomain(name: string, domains: any, FrameworkComm: Folder, services: any)
	if not domains[name] then
		local domainFolder = FrameworkComm:FindFirstChild(name .. "_Domain") or FrameworkComm:WaitForChild(name .. "_Domain", 10)
		if not domainFolder then
			error(`[Framework] Domain "{name}" not found on server or taking too long to replicate.`)
		end
		local remotes = getFrameworkCommRemotes(FrameworkComm)

		-- Reconstruct domain method definitions since the server only sends names/schemas
		local domainDef = { _exposedMethods = {} }
		local encodedMethods = domainFolder:GetAttribute("_methods")
		if encodedMethods then
			local success, decoded = pcall(function() return HttpService:JSONDecode(encodedMethods) end)
			if success and type(decoded) == "table" then
				for _, methodName in ipairs(decoded) do
					domainDef._exposedMethods[methodName] = { fn = function() end }
				end
			end
		end

		local encodedSchemas = domainFolder:GetAttribute("_methodSchemas")
		if encodedSchemas then
			local success, decoded = pcall(function() return HttpService:JSONDecode(encodedSchemas) end)
			if success then
				for methodName, _ in pairs(decoded) do
					-- We only have a dummy fn on the client here, ClientDomainProxy intercepts logic execution natively.
					domainDef._exposedMethods[methodName] = { fn = function() end }
				end
			end
		end

		local encodedReturnSchemas = domainFolder:GetAttribute("_methodReturnSchemas")
		if encodedReturnSchemas then
			local success, decoded = pcall(function() return HttpService:JSONDecode(encodedReturnSchemas) end)
			if success and type(decoded) == "table" then
				for methodName, typeDefs in pairs(decoded) do
					local entry = domainDef._exposedMethods[methodName]
					if not entry then
						entry = { fn = function() end }
						domainDef._exposedMethods[methodName] = entry
					end
					if type(entry.config) ~= "table" then
						entry.config = {}
					end
					entry.config.returns = typeDefs
				end
			end
		end

		local metadataMethods = {}
		for methodName, data in pairs(domainDef._exposedMethods) do
			metadataMethods[methodName] = data
		end

		-- Fetch local domain scripts directly if they exist (authoritative on client if present)
		local ReplicatedStorage = game:GetService("ReplicatedStorage")
		local sharedDomains = ReplicatedStorage:FindFirstChild("Shared") and ReplicatedStorage.Shared:FindFirstChild("Domains")
		if sharedDomains and sharedDomains:FindFirstChild(name) then
			local sharedDef = require(sharedDomains[name])
			if sharedDef and sharedDef._exposedMethods then
				for methodName, data in pairs(sharedDef._exposedMethods) do
					domainDef._exposedMethods[methodName] = data
				end
				for methodName in pairs(metadataMethods) do
					if not sharedDef._exposedMethods[methodName] then
						warn(`[Framework] Domain "{name}" metadata includes "{methodName}" but local shared domain does not.`)
					end
				end
				for methodName in pairs(sharedDef._exposedMethods) do
					if not metadataMethods[methodName] then
						warn(`[Framework] Domain "{name}" local shared domain includes "{methodName}" but server metadata does not.`)
					end
				end
			end
		end

		domains[name] = ClientDomainProxy.new(
			name,
			domainDef,
			remotes.methodEvent :: RemoteFunction,
			remotes.signalEvent :: RemoteEvent,
			-- Use non-yielding lookups for prediction to prevent the UI thread from hanging
			function(serviceName) return services[serviceName] end,
			function(depDomain) return FrameworkClient.getDomain(depDomain, domains, FrameworkComm, services) end
		)
	end
	return domains[name]
end

--[=[
	Starts client controller lifecycle callbacks in dependency order.
	@param controllers controllers: any
	@param options options: StartOptions?
]=]
function FrameworkClient.start(controllers: any, options: StartOptions?)
	local startOptions = options or {}
	local deferLifecycle = startOptions.deferLifecycle == true
	local parallelInit = startOptions.parallelInit == true
	local parallelInitMinCount = if type(startOptions.parallelInitMinCount) == "number" then math.max(2, startOptions.parallelInitMinCount) else 4
	local sortedControllers = DependencySorter.sort(controllers, function(controller)
		return controller._dependencies
	end, "controller")

	local function runParallelInitializers(items: { any }, initializeFn: (any) -> (), failureMessage: string)
		local remaining = #items
		if remaining == 0 then
			return
		end

		local completed = Instance.new("BindableEvent")
		local firstError = nil

		for _, item in items do
			task.spawn(function()
				local ok, err = pcall(function()
					initializeFn(item)
				end)
				if not ok and firstError == nil then
					firstError = err
				end

				remaining -= 1
				if remaining == 0 then
					completed:Fire()
				end
			end)
		end

		completed.Event:Wait()
		completed:Destroy()

		if firstError ~= nil then
			error(`[Framework] {failureMessage}: {tostring(firstError)}`)
		end
	end

	local function shouldParallelInitialize(controller: any): boolean
		if not parallelInit then
			return false
		end
		if type(controller._onInit) ~= "function" then
			return false
		end
		if controller.canParallelInit ~= true and (controller.scope == nil or controller.scope.canParallelInit ~= true) then
			return false
		end

		local dependencies = controller._dependencies
		return type(dependencies) == "table" and #dependencies == 0
	end

	local sequentialInitControllers = {}
	local parallelInitControllers = {}
	for _, controller in sortedControllers do
		if shouldParallelInitialize(controller) then
			table.insert(parallelInitControllers, controller)
		else
			if type(controller._onInit) == "function" then
				table.insert(sequentialInitControllers, controller)
			end
		end
	end

	if #parallelInitControllers < parallelInitMinCount then
		for _, controller in parallelInitControllers do
			table.insert(sequentialInitControllers, controller)
		end
		table.clear(parallelInitControllers)
	end

	for _, controller in sequentialInitControllers do
		ControllerBuilder.initialize(controller)
	end

	if #parallelInitControllers > 0 then
		runParallelInitializers(
			parallelInitControllers,
			ControllerBuilder.initialize,
			"Parallel controller initialization failed"
		)
	end

	local heartbeatConnections = {}
	local renderConnections = {}
	local shuttingDown = false

	local function finishControllerLifecycle()
		if shuttingDown then
			return
		end

		for _, controller in sortedControllers do
			ControllerBuilder.finalize(controller)

			if controller._onHeartbeat then
				local heartbeatHandler = makeFrameDispatcher(controller._onHeartbeat)
				if not heartbeatHandler then
					warn(`[Framework] Invalid onHeartbeat registration for {controller.Name}`)
					continue
				end
				local heartbeatConnection = RunService.Heartbeat:Connect(function(dt)
					heartbeatHandler(dt)
				end)
				if shuttingDown then
					heartbeatConnection:Disconnect()
				else
					table.insert(heartbeatConnections, heartbeatConnection)
				end
			end
			if controller._onRenderStepped then
				local renderHandler = makeFrameDispatcher(controller._onRenderStepped)
				if not renderHandler then
					warn(`[Framework] Invalid onRenderStepped registration for {controller.Name}`)
					continue
				end
				local renderConnection = RunService.RenderStepped:Connect(function(dt)
					renderHandler(dt)
				end)
				if shuttingDown then
					renderConnection:Disconnect()
				else
					table.insert(renderConnections, renderConnection)
				end
			end
		end
	end

	if deferLifecycle then
		task.spawn(finishControllerLifecycle)
	else
		finishControllerLifecycle()
	end

	print("[Framework] All controllers started")

	return function()
		shuttingDown = true

		for _, controller in sortedControllers do
			if type(controller._onStop) == "function" then
				local ok, err = pcall(controller._onStop)
				if not ok then
					warn(`[Framework] Controller onStop failed for {controller.Name}: {err}`)
				end
			end
		end

		for _, conn in heartbeatConnections do
			conn:Disconnect()
		end
		for _, conn in renderConnections do
			conn:Disconnect()
		end
		table.clear(heartbeatConnections)
		table.clear(renderConnections)
	end
end

makeFrameDispatcher = function(listener: any): ((number) -> ())?
	if type(listener) == "function" then
		return listener
	end

	if type(listener) == "table" and type(listener.callback) == "function" then
		local callback = listener.callback
		local fixedDeltaTime = listener.fixedDeltaTime
		if type(fixedDeltaTime) == "number" and fixedDeltaTime > 0 then
			local accumulator = 0
			local maxStepsPerFrame = 8
			return function(dt)
				accumulator += dt
				local steps = 0
				while accumulator >= fixedDeltaTime and steps < maxStepsPerFrame do
					callback(fixedDeltaTime)
					accumulator -= fixedDeltaTime
					steps += 1
				end
			end
		end

		return callback
	end

	return nil
end

return FrameworkClient
