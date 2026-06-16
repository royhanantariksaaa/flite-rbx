--[[
	ChannelState
	Targeted reactive state. Replicates a value only to specific subscribed players.

	Server API:
		state:subscribe(player)          -- Start replicating to this player
		state:unsubscribe(player)        -- Stop replicating to this player
		state:getSubscribers()           -- Get list of subscribed players
		state:set(value)                 -- Set value and replicate ONLY to subscribers
		state:get()                      -- Get current value on server
		state:observe(fn)                -- Observe changes on server
		state:destroy()                  -- Cleanup
]]

local FrameworkSignal = require(script.Parent.FrameworkSignal)

local ChannelState = {}
ChannelState.__index = ChannelState

--[[
	Constructs a new ChannelState.
]]
function ChannelState.new(globalEvent: RemoteEvent, serviceName: string, fieldName: string, default: any)
	local self = setmetatable({}, ChannelState)

	self.isState = true
	self._replicateToClients = true
	self._dispatcher = FrameworkSignal.new(globalEvent, serviceName, fieldName)

	self._default = default
	self._value = default
	self._subscribers = {} -- { [Player] = true }

	self._playerRemoving = game:GetService("Players").PlayerRemoving:Connect(function(player)
		self._subscribers[player] = nil
	end)

	return self
end

--[[ Subscribe a player to receive updates for this state. Also sends them the current value immediately. ]]
function ChannelState:subscribe(player: Player)
	if not self._subscribers[player] then
		self._subscribers[player] = true
		self._dispatcher:fireClient(player, self._value)
	end
end

--[[ Unsubscribe a player from receiving updates for this state. ]]
function ChannelState:unsubscribe(player: Player)
	self._subscribers[player] = nil
end

--[[ Returns an array of currently subscribed players. ]]
function ChannelState:getSubscribers(): { Player }
	local list = {}
	for player, _ in pairs(self._subscribers) do
		if player and player.Parent then
			table.insert(list, player)
		else
			self._subscribers[player] = nil -- Clean up dead references
		end
	end
	return list
end

--[[ Set the value. Replicates ONLY to subscribed clients. ]]
function ChannelState:set(value: any)
	local oldValue = self._value
	self._value = value
	
	-- Replicate ONLY to subscribers
	for player, _ in pairs(self._subscribers) do
		if player and player.Parent then
			self._dispatcher:fireClient(player, value)
		else
			self._subscribers[player] = nil
		end
	end
	
	-- Notify server listeners
	if oldValue ~= value then
		self._dispatcher:fire(value, oldValue)
	end
end

--[[ Get the current value. If requested by a client, verify subscription or return fallback. ]]
function ChannelState:get(player: Player?): any
	if player and typeof(player) == "Instance" and player:IsA("Player") then
		if not self._subscribers[player] then
			return self._default
		end
	end
	return self._value
end

--[[ Like connect(), but fires immediately with the current value. ]]
function ChannelState:observe(callback: (any, any) -> ())
	task.defer(callback, self._value, nil)
	local connection = self._dispatcher:connect(function(value, oldValue)
		callback(value, oldValue)
	end)
	return function()
		connection:disconnect()
	end
end

--[[ Destroy the ChannelState. ]]
function ChannelState:destroy()
	if self._playerRemoving then
		self._playerRemoving:Disconnect()
		self._playerRemoving = nil
	end
	table.clear(self._subscribers)
	self._dispatcher:destroy()
end

return ChannelState
