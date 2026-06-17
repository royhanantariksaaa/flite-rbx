--!native
--!optimize 2
--[=[
	@module MapState
	@within Flite

	Per-player reactive state with sparse-set indexed storage.
	Player keys use a dense array (O(1) access, cache-friendly iteration,
	swap-remove on leave). Non-Player keys fall back to a hash table.

	Inherits FrameworkSignal: fire, fireClient, fireAllClients, connect, etc.
]=]

local Players = game:GetService("Players")
local FrameworkSignal = require(script.Parent.FrameworkSignal)

local NONE = newproxy(false)

local MapState = {}
MapState.__index = MapState
local warnedAliases = {}

local function isPlayer(key: any): boolean
	return typeof(key) == "Instance" and key:IsA("Player")
end

--[=[
	Constructs a new MapState.
	@param globalEvent The shared RemoteEvent
	@param serviceName Owning service name (routing key)
	@param fieldName Field name (routing key, also used as signal name)
	@param default Default/initial value for all players
]=]
function MapState.new(globalEvent: RemoteEvent, serviceName: string, fieldName: string, default: any)
	local self = setmetatable({}, MapState)

	self.isState = true
	self._replicateToClients = true
	self._dispatcher = FrameworkSignal.new(globalEvent, serviceName, fieldName)

	self._default = default
	self._value = default

	-- Sparse set for Player keys: dense array indexed by slot
	self._playerSlots = {}   -- { [Player] -> slotId }
	self._slotPlayers = {}   -- { [slotId] -> Player }
	self._playerValues = {}  -- { [slotId] -> value | NONE }
	self._slotCount = 0

	-- Hash table for non-Player keys
	self._customKeys = {}

	-- Register existing + future players
	for _, player in Players:GetPlayers() do
		self:_registerPlayer(player)
	end

	self._playerAdded = Players.PlayerAdded:Connect(function(player)
		self:_registerPlayer(player)
	end)

	self._playerRemoving = Players.PlayerRemoving:Connect(function(player)
		self:_unregisterPlayer(player)
	end)

	return self
end

function MapState:_registerPlayer(player: Player)
	local slot = self._slotCount + 1
	self._slotCount = slot
	self._playerSlots[player] = slot
	self._slotPlayers[slot] = player
	-- _playerValues[slot] stays nil = "not set" → returns default
end

function MapState:_unregisterPlayer(player: Player)
	local slot = self._playerSlots[player]
	if not slot then return end

	self._playerSlots[player] = nil
	local lastSlot = self._slotCount

	if slot ~= lastSlot then
		-- Swap-remove: move last slot's data into freed slot
		local lastPlayer = self._slotPlayers[lastSlot]
		self._playerSlots[lastPlayer] = slot
		self._slotPlayers[slot] = lastPlayer
		self._playerValues[slot] = self._playerValues[lastSlot]
	end

	self._slotPlayers[lastSlot] = nil
	self._playerValues[lastSlot] = nil
	self._slotCount = lastSlot - 1
end

-- Setters
--[=[ Set the fallback value for ALL unassigned keys. ]=]
function MapState:setDefault(value: any)
	local oldValue = self._value
	self._value = value

	-- Replicate only to players without an explicit override
	local playerValues = self._playerValues
	local slotPlayers = self._slotPlayers
	for slot = 1, self._slotCount do
		if playerValues[slot] == nil then
			self._dispatcher:fireClient(slotPlayers[slot], value)
		end
	end

	if oldValue ~= value then
		self._dispatcher:fire(value, oldValue, nil)
	end
end

--[=[ Set a custom value for a specific key (e.g. Player). ]=]
function MapState:set(key: any, value: any)
	local oldValue = self:get(key)

	if isPlayer(key) then
		local slot = self._playerSlots[key]
		if not slot then
			self:_registerPlayer(key)
			slot = self._playerSlots[key]
		end
		self._playerValues[slot] = if value == nil then NONE else value
		self._dispatcher:fireClient(key, value)
	else
		self._customKeys[key] = if value == nil then NONE else value
	end

	if oldValue ~= value then
		self._dispatcher:fire(value, oldValue, key)
	end
end

local function warnDeprecated(aliasName: string)
	if warnedAliases[aliasName] then return end
	warnedAliases[aliasName] = true
	warn(`[Framework] MapState:{aliasName} is deprecated. Use MapState:set/get/clear instead.`)
end

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
	if isPlayer(key) then
		local slot = self._playerSlots[key]
		if not slot then return end
		if self._playerValues[slot] == nil then return end
		local oldValue = self:get(key)
		self._playerValues[slot] = nil
		self._dispatcher:fireClient(key, self._value)
		if oldValue ~= self._value then
			self._dispatcher:fire(self._value, oldValue, key)
		end
	else
		if self._customKeys[key] == nil then return end
		local oldValue = self:get(key)
		self._customKeys[key] = nil
		if oldValue ~= self._value then
			self._dispatcher:fire(self._value, oldValue, key)
		end
	end
end

function MapState:clearFor(key: any)
	warnDeprecated("clearFor")
	self:clear(key)
end

--[=[ Clear ALL keys. Everything reverts to the fallback default. ]=]
function MapState:clearAll()
	local hadKeys = self._slotCount > 0 or next(self._customKeys) ~= nil
	table.clear(self._playerValues)
	table.clear(self._customKeys)
	self._dispatcher:fireAllClients(self._value)
	if hadKeys then
		self._dispatcher:fire(self._value, nil, nil)
	end
end

-- Getters
--[=[ Get the current value for a key. Returns the specific key value if set, else the fallback default. ]=]
function MapState:get(key: any): any
	if isPlayer(key) then
		local slot = self._playerSlots[key]
		if not slot then return self._value end
		local val = self._playerValues[slot]
		if val == nil then return self._value end
		if val == NONE then return nil end
		return val
	end
	local val = self._customKeys[key]
	if val == nil then return self._value end
	if val == NONE then return nil end
	return val
end

function MapState:getFor(key: any): any
	warnDeprecated("getFor")
	return self:get(key)
end

-- Iteration & Observation
--[=[ Returns an iterator over all keys with explicit overrides and their values. ]=]
function MapState:getEach()
	local slot = 0
	local slotCount = self._slotCount
	local slotPlayers = self._slotPlayers
	local playerValues = self._playerValues
	local customKeys = self._customKeys
	local customKey = nil
	local doingCustom = false

	return function()
		if not doingCustom then
			while slot < slotCount do
				slot += 1
				local val = playerValues[slot]
				if val ~= nil then
					local player = slotPlayers[slot]
					if val == NONE then val = nil end
					return player, val
				end
			end
			doingCustom = true
		end
		local key, rawVal = next(customKeys, customKey)
		if key then
			customKey = key
			return key, if rawVal == NONE then nil else rawVal
		end
		return nil
	end
end

--[=[ Observe a specific key's value. Fires immediately, then on changes.
      Returns a cleanup function. ]=]
function MapState:observe(key: any, callback: (any, any) -> ())
	task.defer(callback, self:get(key), nil)
	local lastValue = self:get(key)

	local connection = self._dispatcher:connect(function(_: any, _: any, changedKey: any)
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
--[=[ Destroy the MapState. Cleans up connections, slots, and the inherited signal. ]=]
function MapState:destroy()
	self._playerAdded:Disconnect()
	self._playerRemoving:Disconnect()
	table.clear(self._playerSlots)
	table.clear(self._slotPlayers)
	table.clear(self._playerValues)
	table.clear(self._customKeys)
	self._slotCount = 0
	self._dispatcher:destroy()
end

return MapState
