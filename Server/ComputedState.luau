--[=[
	@module ComputedState
	@within Flite

	ComputedState
	Derives a reactive value from one or more dependencies (ValueState or MapState).
	It observes all dependencies and reruns the compute function when any change.

	Server API:
		local totalLevel = ComputedState.new({ PlayerLevelMap, ServerMultiplier }, function(levelMap, mult)
			return function(player)
				local l = levelMap:get(player) or 1
				return l * mult:get()
			end
		end)
		
		totalLevel:get(player)
		totalLevel:observe(player, fn)
]=]

local Signal = require(game:GetService("ReplicatedStorage").Libraries.Echo)
local FrameworkSignal = require(script.Parent.FrameworkSignal)

local ComputedState = {}
ComputedState.__index = ComputedState

--[=[
	Constructs a new ComputedState.
	@param globalEvent  (Not strictly needed since computed state doesn't replicate directly, but kept for signature)
	@param serviceName
	@param fieldName
	@param dependencies Array of state objects (ValueState, MapState, or other ComputedState)
	@param computeFn    A function receiving all dependencies, returning either a scalar value OR a generator mapping `function(key) ... end`
]=]
function ComputedState.new(
	globalEvent: RemoteEvent,
	serviceName: string,
	fieldName: string,
	dependencies: { any },
	computeFn: (...any) -> any,
	options: { replicate: boolean? }?
)
	local self = setmetatable({}, ComputedState)

	self.isState = true
	-- Computed state doesn't replicate directly across the network, just fires locally
	self._localSignal = Signal.new()

	self._dependencies = dependencies
	self._computeFn = computeFn
	self._replicateToClients = options ~= nil and options.replicate == true

	self._connections = {}

	if self._replicateToClients then
		self._dispatcher = FrameworkSignal.new(globalEvent, serviceName, fieldName)
		self._default = self:_resolveGenerator(nil)
	end
	
	-- Observe dependencies to trigger recalculations
	-- A naive approach: when ANY dependency changes, we fire nil (global rebuild)
	for _, dep in dependencies do
		if type(dep.observe) == "function" then
			if dep._localSignal then
				table.insert(self._connections, dep._localSignal:connect(function(value, oldValue, changedKey)
					-- Trigger computed recalculation for the specific key, or globally if nil
					self:_recalculate(changedKey)
				end))
			elseif dep._dispatcher then
				table.insert(self._connections, dep._dispatcher:connect(function(value, oldValue, changedKey)
					-- Trigger computed recalculation for the specific key, or globally if nil
					self:_recalculate(changedKey)
				end))
			end
		end
	end

	return self
end

--[=[ Internal wrapper to fetch scalar values or contextual map values ]=]
function ComputedState:_resolveGenerator(key: any)
	local result = self._computeFn(table.unpack(self._dependencies))
	if type(result) == "function" then
		return result(key)
	end
	return result
end

--[=[ Force recalculation and fire update signals ]=]
function ComputedState:_recalculate(changedKey: any)
	-- Ideally, this caches previous values per key and only fires if changed, 
	-- but for simplicity, we instantly tell subscribers a dependency shifted.
	local current = self:_resolveGenerator(changedKey)
	if self._dispatcher then
		if typeof(changedKey) == "Instance" and changedKey:IsA("Player") then
			self._dispatcher:fireClient(changedKey, current)
		else
			self._dispatcher:fireAllClients(current)
		end
	end
	self._localSignal:fire(current, nil, changedKey)
end

--[=[ Get the current computed value for a key (or nil if global scalar) ]=]
function ComputedState:get(key: any?): any
	return self:_resolveGenerator(key)
end

--[=[ Observe computed changes for a specific key (or global scalar) ]=]
function ComputedState:observe(key: any?, callback: (any, any) -> ())
	task.defer(callback, self:get(key), nil)

	local lastValue = self:get(key)
	local connection = self._localSignal:connect(function(_ : any, _ : any, changedKey: any)
		if changedKey == nil or changedKey == key then
			local currentValue = self:get(key)
			if currentValue ~= lastValue then
				local prev = lastValue
				lastValue = currentValue
				callback(currentValue, prev)
			end
		end
	end)

	return function()
		connection:disconnect()
	end
end

--[=[
	Disconnects computed-state subscriptions and releases local signal resources.
]=]
function ComputedState:destroy()
	for _, conn in self._connections do
		conn:disconnect()
	end
	table.clear(self._connections)
	if self._dispatcher then
		self._dispatcher:destroy()
		self._dispatcher = nil
	end
	self._localSignal:destroy()
end

return ComputedState
