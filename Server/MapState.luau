--[=[
	@module MapState
	@within Flite

	MapState
	Per-player reactive state. Extends FrameworkSignal with value storage.

	Inheritance:
		FrameworkSignal (fire, fireClient, fireAllClients, connect, etc.)
		`-- MapState (adds _value, _perPlayer, get/set/clear/observe)

	The set/setFor methods store the value AND fire the inherited signal
	methods to replicate to clients and notify server listeners.

	Server API (inherited from FrameworkSignal):
		state:fire(...)               -> notify server listeners only
		state:fireClient(player, ...) -> fire to one client
		state:connect(fn)             -> subscribe server-side

	Server API (MapState-specific):
		state:setDefault(value)          -- Set the fallback value for all missing keys
		state:set(key, value)            -- Set custom value for one key (e.g. Player)
		state:setFilter(predicate, val)  -- Set for keys matching predicate
		state:get(key)                   -- Get current value for key
		state:getEach()                  -- Returns an iterator for all keys and their values
		state:clear(key)                 -- Clear a specific key
		state:clearAll()                 -- Clear ALL keys
		state:observe(key, fn)           -- Observe a specific key's value
		state:destroy()                  -- Cleanup
]=]

local Players = game:GetService("Players")
local FrameworkSignal = require(script.Parent.FrameworkSignal)

-- Sentinel value for storing `nil` in the _perPlayer table
local NONE = newproxy(false)

local MapState = {}
MapState.__index = MapState
local warnedAliases = {}

--[=[
	Constructs a new MapState.
	@param globalEvent   The shared RemoteEvent
	@param serviceName   Owning service name (routing key)
	@param fieldName     Field name (routing key, also used as signal name)
	@param default       Default/initial value for all players
]=]
function MapState.new(globalEvent: RemoteEvent, serviceName: string, fieldName: string, default: any)
	local self = setmetatable({}, MapState)

	self.isState = true
	self._replicateToClients = true
	self._dispatcher = FrameworkSignal.new(globalEvent, serviceName, fieldName)
	
	-- MapState-specific: value storage
	self._default = default           -- Initial value (used for client discovery)
	self._value = default             -- Current top-level value
	self._perPlayer = {}              -- Player -> value (or NONE for explicit nil)

	-- Auto-cleanup per-player data when a player leaves
	self._playerRemoving = Players.PlayerRemoving:Connect(function(player)
		self._perPlayer[player] = nil
	end)

	return self
end

-- Setters
--[=[ Set the fallback value for ALL unassigned keys. ]=]
function MapState:setDefault(value: any)
	local oldValue = self._value
	self._value = value
	-- Replicate only to clients that don't have a per-player override
	local Players = game:GetService("Players")
	for _, player in Players:GetPlayers() do
		if self._perPlayer[player] == nil then
			self._dispatcher:fireClient(player, value)
		end
	end
	if oldValue ~= value then
		self._dispatcher:fire(value, oldValue, nil)
	end
end

--[=[ Set a custom value for a specific key (e.g. Player). ]=]
function MapState:set(key: any, value: any)
	local oldValue = self:get(key)
	
	-- We still need to support instances like Player objects
	self._perPlayer[key] = if value == nil then NONE else value
	
	if typeof(key) == "Instance" and key:IsA("Player") then
		self._dispatcher:fireClient(key, value)
	end
	
	if oldValue ~= value then
		self._dispatcher:fire(value, oldValue, key)
	end
end

local function warnDeprecated(aliasName: string)
	if warnedAliases[aliasName] then
		return
	end
	warnedAliases[aliasName] = true
	warn(`[Framework] MapState:{aliasName} is deprecated. Use MapState:set/get/clear instead.`)
end

--[=[
	Sets the value stored for a map key and replicates the change.
	@param key key: any
	@param value value: any
	@return nil
]=]
function MapState:setFor(key: any, value: any)
	warnDeprecated("setFor")
	self:set(key, value)
end

--[=[ Set a value for keys matching a predicate function. ]=]
function MapState:setFilter(predicate: (any, any) -> boolean, value: any)
	for key, val in self:getEach() do
		if predicate(key, val) then
			self:set(key, value)
		end
	end
end

-- Clearing
--[=[ Clear a specific key. It reverts to the fallback default. ]=]
function MapState:clear(key: any)
	if self._perPlayer[key] == nil then return end
	local oldValue = self:get(key)
	self._perPlayer[key] = nil
	
	if typeof(key) == "Instance" and key:IsA("Player") then
		self._dispatcher:fireClient(key, self._value)
	end
	
	if oldValue ~= self._value then
		self._dispatcher:fire(self._value, oldValue, key)
	end
end

--[=[
	Clears the value stored for a map key and replicates the change.
	@param key key: any
]=]
function MapState:clearFor(key: any)
	warnDeprecated("clearFor")
	self:clear(key)
end

--[=[ Clear ALL keys. Everything reverts to the fallback default. ]=]
function MapState:clearAll()
	local hadKeys = next(self._perPlayer) ~= nil
	table.clear(self._perPlayer)
	self._dispatcher:fireAllClients(self._value)
	if hadKeys then
		self._dispatcher:fire(self._value, nil, nil)
	end
end

-- Getters
--[=[ Get the current value for a key. Returns the specific key value if set, else the fallback default. ]=]
function MapState:get(key: any): any
	local pv = self._perPlayer[key]
	if pv == nil then return self._value end
	if pv == NONE then return nil end
	return pv
end

--[=[
	Reads the value for a specific key.
	@param key Key used by this API.
	@return any
]=]
function MapState:getFor(key: any): any
	warnDeprecated("getFor")
	return self:get(key)
end

-- Iteration & Observation
--[=[ Returns an iterable mapping of all active keys and their current values. ]=]
function MapState:getEach()
	return function(_, k)
		local nextKey, nextValue = next(self._perPlayer, k)
		if nextKey ~= nil then
			-- Map NONE to nil for correctness, though NONE should rarely be iterated
			return nextKey, if nextValue == NONE then nil else nextValue
		end
		return nil, nil
	end, self._perPlayer, nil
end

--[=[ Observe a specific key's value. Fires immediately, then on changes.
     Returns a cleanup function. ]=]
--[=[
	Subscribes to value changes.
	@param key Key used by this API.
	@param callback Callback invoked by this API.
]=]
function MapState:observe(key: any, callback: (any, any) -> ())
	task.defer(callback, self:get(key), nil)
	local lastValue = self:get(key)

	local connection = self._dispatcher:connect(function(_ : any, _ : any, changedKey: any)
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

-- Cleanup
--[=[ Destroy the MapState. Cleans up connections and the inherited signal. ]=]
function MapState:destroy()
	self._playerRemoving:Disconnect()
	table.clear(self._perPlayer)
	self._dispatcher:destroy()
end

return MapState
