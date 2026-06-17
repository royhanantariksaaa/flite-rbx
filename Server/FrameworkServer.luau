--[=[
	@module FrameworkServer
	@within Flite

	FrameworkServer
	Handles Server-side service creation, domain routing, and lifecycle bootstrapping.
]=]

local RunService = game:GetService("RunService")
local serviceBuilderModule = nil
for _, child in ipairs(script.Parent:GetChildren()) do
	if child.Name == "ServiceBuilder" and child:IsA("ModuleScript") then
		serviceBuilderModule = child
		break
	end
end
if not serviceBuilderModule then
	error("[Framework] ServiceBuilder module is missing.")
end
local ServiceBuilder = require(serviceBuilderModule)
local ServerDomainProxy = require(script.Parent.ServerDomainProxy)
local DomainBuilder = require(script.Parent.Parent.Shared.DomainBuilder)
local DependencySorter = require(script.Parent.Parent.Shared.DependencySorter)
local SchemaPublisher = require(script.Parent.Parent.Shared.SchemaPublisher)

local FrameworkServer = {}
local makeFrameDispatcher: ((any) -> ((number) -> ())?)
type StartOptions = {
	deferLifecycle: boolean?,
	parallelInit: boolean?,
	manifestOnly: boolean?,
	parallelInitMinCount: number?,
}

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

--[=[
	Creates and registers a server service from a setup callback.
	@param name Service name.
	@param setupFn Configures the service builder context.
	@param services Service registry table.
	@param domains Domain registry table.
	@param stateEvent RemoteEvent used for state replication.
	@param signalEvent RemoteEvent used for reliable signals.
	@param unreliableSignalEvent UnreliableRemoteEvent used for unreliable signals.
	@param options Optional server start options.
	@return any
]=]
function FrameworkServer.createService(
	name: string,
	setupFn: (service: any) -> (),
	services: any,
	domains: any,
	stateEvent: RemoteEvent,
	signalEvent: RemoteEvent,
	unreliableSignalEvent: UnreliableRemoteEvent,
	options: StartOptions?
)
	local service = ServiceBuilder.build(stateEvent, signalEvent, unreliableSignalEvent, name, function(dependencyName)
		local serviceDep = services[dependencyName]
		if serviceDep then
			return serviceDep
		end
		local domainDep = domains[dependencyName]
		if domainDep then
			return domainDep
		end
		error(`[Framework] Dependency "{dependencyName}" not found as service or domain`)
	end, setupFn, {
		manifestOnly = options and options.manifestOnly == true,
	})
	services[name] = service
	return service
end

--[=[
	Creates and registers a server-side domain definition.
	@param name name: string
	@param setupFn Configures the domain builder context.
]=]
function FrameworkServer.createDomain(name: string, setupFn: (domain: any) -> (), domains: any, services: any)
	local domainDef = DomainBuilder.build(name, function(domainName)
		assert(domains[domainName], `[Framework] Domain "{domainName}" not found`)
		return domains[domainName]
	end, setupFn)

	local proxy = ServerDomainProxy.new(domainDef, function(serviceName)
		assert(services[serviceName], `[Framework] Service "{serviceName}" not found`)
		return services[serviceName]
	end, function(domainName)
		assert(domains[domainName], `[Framework] Domain "{domainName}" not found`)
		return domains[domainName]
	end)

	-- Create Domain network folder for client attribute discovery
	local domainFolder = Instance.new("Folder")
	domainFolder.Name = name .. "_Domain"
	local frameworkComm = game:GetService("ReplicatedStorage"):WaitForChild("FrameworkComm", 10)
	if not frameworkComm then
		error("[Framework] FrameworkComm folder missing; cannot publish domain metadata")
	end
	local existing = frameworkComm:FindFirstChild(domainFolder.Name)
	if existing then
		existing:Destroy()
	end
	domainFolder.Parent = frameworkComm

	-- Publish Method Schemas for the client-side BufferCodec Domain interactions
	SchemaPublisher.publishMethodSchemas(domainFolder, proxy._exposedMethods)

	domains[name] = proxy
	return proxy
end

--[=[
	Starts server services and domains, including lifecycle and networking setup.
	@param services services: any
	@param domains domains: any
	@param options options: StartOptions?
]=]
function FrameworkServer.start(services: any, domains: any, options: StartOptions?)
	local startOptions = options or {}
	local deferLifecycle = startOptions.deferLifecycle == true
	local parallelInit = startOptions.parallelInit == true
	local parallelInitMinCount = if type(startOptions.parallelInitMinCount) == "number" then math.max(2, startOptions.parallelInitMinCount) else 4
	local sortedServices = DependencySorter.sort(services, function(service)
		local dependencies = {}
		for _, dependencyName in service._dependencies do
			if services[dependencyName] then
				table.insert(dependencies, dependencyName)
			elseif not domains[dependencyName] then
				-- Preserve unknown dependencies so the sorter can fail fast.
				table.insert(dependencies, dependencyName)
			end
		end
		return dependencies
	end, "service")

	-- Track connections for cleanup
	local heartbeatConnections = {}
	local playerAddedConnections = {}
	local playerRemovingConnections = {}
	local playerCharacterConnections = {}
	local shuttingDown = false
	local shutdownReason = nil

	local function disconnectCharacterConnections(player: Player)
		local connections = playerCharacterConnections[player]
		if not connections then
			return
		end

		for _, connection in ipairs(connections) do
			connection:Disconnect()
		end
		playerCharacterConnections[player] = nil
	end

	local function attachCharacterLifecycle(player: Player)
		disconnectCharacterConnections(player)

		local addedConnection = player.CharacterAdded:Connect(function(character)
			for _, service in sortedServices do
				if service._onPlayerSpawned then
					service._onPlayerSpawned(player, character)
				end
			end
		end)

		local removingConnection = player.CharacterRemoving:Connect(function(character)
			for _, service in sortedServices do
				if service._onPlayerDespawned then
					service._onPlayerDespawned(player, character)
				end
			end
		end)

		playerCharacterConnections[player] = {
			addedConnection,
			removingConnection,
		}

		local existingCharacter = player.Character
		if existingCharacter then
			for _, service in sortedServices do
				if service._onPlayerSpawned then
					service._onPlayerSpawned(player, existingCharacter)
				end
			end
		end
	end

	local function runParallelInitializers(items: { any }, initializeFn: (any) -> (), errorContext: string)
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
			error(`[Framework] {errorContext}: {tostring(firstError)}`)
		end
	end

	local function shouldParallelInitialize(service: any): boolean
		if not parallelInit then
			return false
		end
		if type(service._onInit) ~= "function" then
			return false
		end
		if service.canParallelInit ~= true then
			return false
		end

		local dependencies = service._dependencies
		return type(dependencies) == "table" and #dependencies == 0
	end

	local sequentialInitServices = {}
	local parallelInitServices = {}
	for _, service in sortedServices do
		if service._exposedMethods then
			for methodName in service._exposedMethods do
				local exposedField = service[methodName]
				local isExposedSignal = type(exposedField) == "table" and type(exposedField.fire) == "function"
				if type(exposedField) ~= "function" and not isExposedSignal then
					error(`[Framework] Service "{service.Name}" exposes method "{methodName}" but it is not implemented as a function!`)
				end
			end
		end

		if shouldParallelInitialize(service) then
			table.insert(parallelInitServices, service)
		else
			if type(service._onInit) == "function" then
				table.insert(sequentialInitServices, service)
			end
		end
	end

	if #parallelInitServices < parallelInitMinCount then
		for _, service in parallelInitServices do
			table.insert(sequentialInitServices, service)
		end
		table.clear(parallelInitServices)
	end

	for _, service in sequentialInitServices do
		ServiceBuilder.initialize(service)
	end

	if #parallelInitServices > 0 then
		runParallelInitializers(
			parallelInitServices,
			ServiceBuilder.initialize,
			"Parallel service initialization failed"
		)
	end

	local function finishServiceLifecycle()
		if shuttingDown then
			return
		end

		for _, service in sortedServices do
			ServiceBuilder.finalize(service)

			if service._onHeartbeat then
				local heartbeatHandler = makeFrameDispatcher(service._onHeartbeat)
				if not heartbeatHandler then
					warn(`[Framework] Invalid onHeartbeat registration for {service.Name}`)
					continue
				end
				local connection = RunService.Heartbeat:Connect(function(dt)
					heartbeatHandler(dt)
				end)
				if shuttingDown then
					connection:Disconnect()
				else
					table.insert(heartbeatConnections, connection)
				end
			end
		end

		local Players = game:GetService("Players")
		for _, player in Players:GetPlayers() do
			for _, service in sortedServices do
				if service._onPlayerAdded then
					service._onPlayerAdded(player)
				end
			end
			attachCharacterLifecycle(player)
		end

		local playerAddedConnection = Players.PlayerAdded:Connect(function(player)
			for _, service in sortedServices do
				if service._onPlayerAdded then
					service._onPlayerAdded(player)
				end
			end
			attachCharacterLifecycle(player)
		end)
		if shuttingDown then
			playerAddedConnection:Disconnect()
		else
			table.insert(playerAddedConnections, playerAddedConnection)
		end

		local playerRemovingConnection = Players.PlayerRemoving:Connect(function(player)
			for _, service in sortedServices do
				if service._onPlayerRemoving then
					service._onPlayerRemoving(player)
				end
			end
			disconnectCharacterConnections(player)
		end)
		if shuttingDown then
			playerRemovingConnection:Disconnect()
		else
			table.insert(playerRemovingConnections, playerRemovingConnection)
		end
	end

	if deferLifecycle then
		task.spawn(finishServiceLifecycle)
	else
		finishServiceLifecycle()
	end

	game:BindToClose(function()
		shutdownReason = "ServerShutdown"
		for _, service in sortedServices do
			if type(service._beforeServerShutdown) == "function" then
				local ok, err = pcall(service._beforeServerShutdown, shutdownReason)
				if not ok then
					warn(`[Framework] beforeServerShutdown failed for {service.Name}: {err}`)
				end
			end
		end
	end)

	print("[Framework] All services started")

	-- Return cleanup function for Framework shutdown
	return function()
		shuttingDown = true

		for _, conn in heartbeatConnections do
			conn:Disconnect()
		end
		for _, conn in playerAddedConnections do
			conn:Disconnect()
		end
		for _, conn in playerRemovingConnections do
			conn:Disconnect()
		end
		for player in pairs(playerCharacterConnections) do
			disconnectCharacterConnections(player)
		end
		table.clear(heartbeatConnections)
		table.clear(playerAddedConnections)
		table.clear(playerRemovingConnections)
		table.clear(playerCharacterConnections)

		for _, service in sortedServices do
			ServiceBuilder.destroy(service)
		end
	end
end

return FrameworkServer
