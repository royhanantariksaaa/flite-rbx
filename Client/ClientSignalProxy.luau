--[[
	ClientSignalProxy
	Client-side proxy for a FrameworkSignal, used within ServiceProxy.
	Wraps the global SignalEvent RemoteEvent for subscribing + firing to server.

	API:
		signal:connect(fn)       -- Subscribe to server-fired events
		signal:once(fn)          -- Subscribe once, auto-disconnect
		signal:fireServer(...)   -- Fire event to the server
]]

local Signal = require(game:GetService("ReplicatedStorage").Libraries.WeaveSignal)
local BufferCodec = require(script.Parent.Parent.Shared.BufferCodec)

local ClientSignalProxy = {}
ClientSignalProxy.__index = ClientSignalProxy

--[[
	Create a new client-side signal proxy.
	@param signalEvent   The global SignalEvent RemoteEvent
	@param serviceName   Owning service name
	@param signalName    Signal name
	@param schemas       (Optional) Array of `t` schema objects for buffer compression
]]
function ClientSignalProxy.new(signalEvent: any, serviceName: string, signalName: string, schemas: {any}?)
	local self = setmetatable({}, ClientSignalProxy)

	self._signalEvent = signalEvent
	self._serviceName = serviceName
	self._signalName = signalName
	self._schemas = schemas

	-- Local signal that init.luau dispatches into when it receives
	-- a matching (serviceName, signalName) from the server
	self._localSignal = Signal.new()

	return self
end

--[[ Subscribe to this signal. Callback fires whenever the server fires it. ]]
function ClientSignalProxy:connect(callback: (...any) -> ())
	return self._localSignal:connect(callback)
end

--[[ Subscribe once. Auto-disconnects after the first fire. ]]
function ClientSignalProxy:once(callback: (...any) -> ())
	return self._localSignal:once(callback)
end

--[[ Fire this signal to the server. ]]
function ClientSignalProxy:fireServer(...)
	local args = table.pack(...)
	if self._schemas then
		local buf, inst_array = BufferCodec.serialize(self._schemas, table.unpack(args, 1, args.n))
		self._signalEvent:FireServer(self._serviceName, self._signalName, buf, inst_array)
	else
		self._signalEvent:FireServer(self._serviceName, self._signalName, table.unpack(args, 1, args.n))
	end
end

--[[ Called by init.luau's central listener to dispatch incoming server events. ]]
function ClientSignalProxy:_dispatch(...)
	self._localSignal:fire(...)
end

--[[ Cleanup. ]]
function ClientSignalProxy:destroy()
	self._localSignal:destroy()
end

return ClientSignalProxy
