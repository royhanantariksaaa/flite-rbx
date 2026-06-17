--!optimize 2
--[=[
	@module GlobalValueState
	@within Flite

	GlobalValueState
	Synchronizes a single value across all servers in an experience using
	MemoryStoreService (for atomic updates) and MessagingService (for fast replication).

	Server API:
		state:get() 
		state:set(value)
		state:update(transformFn) -- Atomic UpdateAsync wrapper
		state:observe(fn)
		state:destroy()
]=]

local MemoryStoreService = game:GetService("MemoryStoreService")
local MessagingService = game:GetService("MessagingService")
local Signal = require(game:GetService("ReplicatedStorage").Libraries.Echo)
local Promise = require(game:GetService("ReplicatedStorage").Libraries.Promise)
local FrameworkSignal = require(script.Parent.FrameworkSignal)

local GlobalValueState = {}
GlobalValueState.__index = GlobalValueState

--[=[
	Constructs a new GlobalValueState.
	Because MemoryStore GetAsync yields, the value might take a few frames to populate.
	@param name      Name of the global key.
	@param default   Fallback value if the key does not exist yet.
]=]
function GlobalValueState.new(
	globalEventOrName: RemoteEvent | string,
	serviceNameOrDefault: string | any,
	fieldNameOrNil: string?,
	defaultOrNil: any?
)
	local self = setmetatable({}, GlobalValueState)

	self.isState = true

	local name: string
	if type(globalEventOrName) == "string" then
		name = globalEventOrName
		self._default = serviceNameOrDefault
	else
		local globalEvent = globalEventOrName
		local serviceName = serviceNameOrDefault :: string
		local fieldName = fieldNameOrNil :: string
		name = serviceName .. "_" .. fieldName
		self._default = defaultOrNil
		self._dispatcher = FrameworkSignal.new(globalEvent, serviceName, fieldName)
		self._replicateToClients = true
	end

	self._name = "GlobalState_" .. name
	self._value = self._default
	
	-- We use a SortedMap to guarantee expiration if the game dies
	-- Expiration is set to 24 hours, refreshed on every write
	self._map = MemoryStoreService:GetSortedMap("Framework_GlobalValues")
	
	self._localSignal = Signal.new()
	
	-- 1. Initialize value
	self:_initialize()
	
	-- 2. Subscribe to fast cross-server updates
	self._subscription = MessagingService:SubscribeAsync(self._name, function(message)
		local newValue = message.Data
		self:_applyValue(newValue)
	end)
	
	return self
end

--[=[
	Applies a replicated global value locally and notifies observers.
	@param newValue newValue: any
]=]
function GlobalValueState:_applyValue(newValue: any)
	if self._value == newValue then
		return
	end

	local old = self._value
	self._value = newValue
	if self._dispatcher then
		self._dispatcher:fireAllClients(newValue)
	end
	self._localSignal:fire(newValue, old)
end

--[=[
	Loads the initial global value asynchronously from MemoryStore.
]=]
function GlobalValueState:_initialize()
	task.spawn(function()
		local success, result = pcall(function()
			return self._map:GetAsync(self._name)
		end)
		
		if success and result ~= nil then
			-- It exists on the backend already!
			self:_applyValue(result)
		end
	end)
end

--[=[
	Returns the current cached global value.
	@return any
]=]
function GlobalValueState:get()
	return self._value
end

--[=[
	Writes a new value.
	@param newValue Value to write.
]=]
function GlobalValueState:set(newValue: any)
	return self:update(function() return newValue end)
end

--[=[ Function mapping to MemoryStore UpdateAsync ]=]
function GlobalValueState:update(transformFn: (any) -> any)
	return Promise.new(function(resolve, reject)
		task.spawn(function()
			local success, finalValue = pcall(function()
				return self._map:UpdateAsync(self._name, function(backendValue)
					-- If nil, use the default as the base
					if backendValue == nil then
						backendValue = self._default
					end
					
					-- Run developer logic
					return transformFn(backendValue)
				end, 86400) -- 24 hours expire
			end)
			
			if success then
				-- Immediately update local cache to prevent stale reads before MessagingService echoes back
				self:_applyValue(finalValue)

				pcall(function()
					MessagingService:PublishAsync(self._name, finalValue)
				end)
				
				resolve(finalValue)
			else
				warn(`[Framework] Failed to update GlobalValue '{self._name}'`)
				reject("Failed to update MemoryStore")
			end
		end)
	end)
end

--[=[
	Subscribes to global value changes and immediately receives the current value.
	@param callback Receives the new value and previous value.
	@return () -> ()
]=]
function GlobalValueState:observe(callback: (any, any) -> ())
	task.defer(callback, self._value, nil)
	local connection = self._localSignal:connect(callback)
	return function()
		connection:disconnect()
	end
end

--[=[
	Disconnects global replication resources and local observers.
]=]
function GlobalValueState:destroy()
	if self._subscription then
		self._subscription:Disconnect()
		self._subscription = nil
	end
	if self._dispatcher then
		self._dispatcher:destroy()
		self._dispatcher = nil
	end
	self._localSignal:destroy()
end

return GlobalValueState
