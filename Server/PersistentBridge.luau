--[[
	PersistentBridge
	Automatically syncs PlayerState fields with DataStoreWrapper sessions.

	On player join:
		1. Starts a session for the player (loads + returns data in one call)
		2. Reads the stored data and sets each field via state:set()
		3. Calls onPlayerReady callback if registered

	On player leave:
		1. Stops the session (triggers flush + save)

	Usage (called internally by ServiceBuilder):
		PersistentBridge.wire(service, { store = dataStore, fields = { "Coins", "Gems" } })
]]

local Players = game:GetService("Players")
local DataStoreWrapper = require(script.Parent.DataStoreWrapper)

local PersistentBridge = {}

--[[
	Wire up automatic persistence between PlayerState fields and a DataStoreWrapper store.
	@param service             The service table (with PlayerState instances attached)
	@param config              { store = DataStoreWrapper.Store, fields = { "fieldName1", ... } }
	@param onPlayerReady       Optional callback: (service, player, data) -> called after data loads
	@param onPlayerSessionEnd  Optional callback: (service, player, data, reason) -> called before session teardown
]]
function PersistentBridge.wire(
	service: any,
	config: { store: any, fields: { string } },
	onPlayerReady: ((any, Player, { [string]: any }) -> ())?,
	onPlayerSessionEnd: ((any, Player, { [string]: any }, string?) -> ())?
)
	local store = config.store
	local fields = config.fields

	local playerObservers = {}
	local alive = true

	local function disconnectObservers(player: Player)
		local observers = playerObservers[player]
		if observers then
			for _, disconnect in ipairs(observers) do
				disconnect()
			end
			playerObservers[player] = nil
		end
	end

	local function handleAdded(player: Player)
		if not alive then
			return
		end
		local key = tostring(player.UserId)

		-- Start session: loads data, applies migrations, returns it directly
		local data = DataStoreWrapper.startSession(store, key)

		if not player:IsDescendantOf(Players) then
			-- The player left while we were loading.
			-- Do not initialize any PlayerState for a disconnected user.
			DataStoreWrapper.stopSession(store, key)
			return
		end

		playerObservers[player] = {}

		-- Sync each field from loaded data into the PlayerState
		if data then
			for _, fieldName in fields do
				local state = service[fieldName]
				if state then
					if data[fieldName] ~= nil then
						-- This also fires the global StateEvent to replicate to the client
						state:set(player, data[fieldName])
					end

					-- Observe future state changes and write them back to the session for auto-saving
					local function writeBack(newVal)
						DataStoreWrapper.update(store, key, function(currentData)
							currentData[fieldName] = newVal
							return currentData
						end)
					end

					local disconnect = nil
					local isMapState = type(state.setFilter) == "function"
					if type(state.observe) == "function" then
						if isMapState then
							disconnect = state:observe(player, function(newVal)
								writeBack(newVal)
							end)
						else
							disconnect = state:observe(function(newVal)
								writeBack(newVal)
							end)
						end
					end

					if type(disconnect) == "function" then
						table.insert(playerObservers[player], disconnect)
					end
				end
			end
		end

		-- Fire the onPlayerReady callback if the service registered one
		if onPlayerReady then
			onPlayerReady(service, player, data or {})
		end
	end

	local function handleRemoving(player: Player, reason: string?)
		local key = tostring(player.UserId)
		local data = DataStoreWrapper.getSessionData(store, key) or {}

		if onPlayerSessionEnd then
			onPlayerSessionEnd(service, player, data, reason)
		end

		disconnectObservers(player)

		-- Stop the session (flushes dirty data, clears cache)
		DataStoreWrapper.stopSession(store, key)
	end

	local playerAddedConnection = Players.PlayerAdded:Connect(handleAdded)
	local playerRemovingConnection = Players.PlayerRemoving:Connect(handleRemoving)

	for _, player in Players:GetPlayers() do
		task.spawn(handleAdded, player)
	end

	return function()
		alive = false
		playerAddedConnection:Disconnect()
		playerRemovingConnection:Disconnect()
		for player in pairs(playerObservers) do
			handleRemoving(player, "ServerShutdown")
		end
	end
end

return PersistentBridge
