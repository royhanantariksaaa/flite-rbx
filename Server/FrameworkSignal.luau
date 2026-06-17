--!native
--!optimize 2
--[=[
	@module FrameworkSignal
	@within Flite

	FrameworkSignal
	Unified signal for both serverâ†”client (network) and serverâ†”server (local) events.
	This is the base class that PlayerState inherits from.

	Architecture:
		All FrameworkSignal instances share a single global RemoteEvent (SignalEvent).
		Each fire includes (serviceName, signalName) as routing identifiers.
		A local Signal handles server-to-server pub/sub without touching the network.

	Server API:
		signal:fire(...)                 -- Fire to local server listeners only
		signal:fireClient(player, ...)   -- Fire to one client
		signal:fireAllClients(...)       -- Broadcast to all clients
		signal:fireClientAndLocal(player, ...) -- Fire to one client + local listeners
		signal:fireAll(...)              -- Broadcast to all clients + local listeners
		signal:connect(fn)              -- Subscribe (server-side)
		signal:once(fn)                 -- Subscribe once, then auto-disconnect
		signal:wait()                   -- Yield until next fire
		signal:destroy()                -- Cleanup

	Client API (handled by ClientSignalProxy):
		signal:connect(fn)              -- Subscribe to server-fired events
		signal:once(fn)                 -- Subscribe once
		signal:fireServer(...)          -- Fire to the server
]=]

local Signal = require(game:GetService("ReplicatedStorage").Libraries.Echo)

local FrameworkSignal = {}
FrameworkSignal.__index = FrameworkSignal

--[=[
	Constructs a new FrameworkSignal.
	@param globalEvent   The single shared RemoteEvent OR UnreliableRemoteEvent for signal traffic
	@param serviceName   Name of the owning service (routing key)
	@param signalName    Name of this signal (routing key)
]=]
function FrameworkSignal.new(globalEvent: RemoteEvent | UnreliableRemoteEvent, serviceName: string, signalName: string)
	local self = setmetatable({}, FrameworkSignal)

	self._globalEvent = globalEvent   -- Shared RemoteEvent/UnreliableRemoteEvent (injected, not created)
	self._serviceName = serviceName   -- e.g. "CombatService"
	self._signalName = signalName     -- e.g. "playerDied"

	-- Local signal for server-to-server listeners
	self._localSignal = Signal.new()

	return self
end

-- Firing
--[=[ Fire to local server listeners only. Does NOT cross the network. ]=]
function FrameworkSignal:fire(...)
	self._localSignal:fire(...)
end

--[=[ Fire to a specific client via the global RemoteEvent.
     Does NOT fire local server listeners. ]=]
--[=[
	Fires the signal for one client.
	@param player Player affected by this API.
]=]
function FrameworkSignal:fireClient(player: Player, ...)
	self._globalEvent:FireClient(player, self._serviceName, self._signalName, ...)
end

--[=[ Broadcast to ALL connected clients via the global RemoteEvent.
     Does NOT fire local server listeners. ]=]
--[=[
	Fires the signal for all clients.
]=]
function FrameworkSignal:fireAllClients(...)
	self._globalEvent:FireAllClients(self._serviceName, self._signalName, ...)
end

--[=[ Fire to one client AND local server listeners. ]=]
function FrameworkSignal:fireClientAndLocal(player: Player, ...)
	self._globalEvent:FireClient(player, self._serviceName, self._signalName, ...)
	self._localSignal:fire(...)
end

--[=[ Broadcast to ALL clients AND local server listeners. ]=]
function FrameworkSignal:fireAll(...)
	self._globalEvent:FireAllClients(self._serviceName, self._signalName, ...)
	self._localSignal:fire(...)
end

-- Subscribing
--[=[ Subscribe to this signal (server-side). Returns an RBXScriptConnection. ]=]
function FrameworkSignal:connect(callback: (...any) -> ())
	return self._localSignal:connect(callback)
end

--[=[ Subscribe once. Auto-disconnects after the first fire. ]=]
function FrameworkSignal:once(callback: (...any) -> ())
	return self._localSignal:once(callback)
end

--[=[ Yield the calling thread until this signal fires. Returns the fired args. ]=]
function FrameworkSignal:wait()
	return self._localSignal:wait()
end

-- Cleanup
--[=[ Destroy the signal and disconnect all listeners. ]=]
function FrameworkSignal:destroy()
	self._localSignal:destroy()
end

return FrameworkSignal
