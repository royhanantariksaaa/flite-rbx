--[[
	ValueState
	Global reactive state (scalar). Extends FrameworkSignal with value storage.
	Replaces the old approach where `useSharedState` reused `PlayerState`.

	Server API:
		state:set(value)                 -- Set value for all clients
		state:get()                      -- Get current value
		state:observe(fn)                -- Observe changes
		state:destroy()                  -- Cleanup
]]

local FrameworkSignal = require(script.Parent.FrameworkSignal)

local ValueState = {}
ValueState.__index = ValueState

--[[
	Constructs a new ValueState.
]]
function ValueState.new(globalEvent: RemoteEvent, serviceName: string, fieldName: string, default: any)
	local self = setmetatable({}, ValueState)

	self.isState = true
	self._replicateToClients = true
	self._dispatcher = FrameworkSignal.new(globalEvent, serviceName, fieldName)
	self._default = default
	self._value = default

	return self
end

--[[ Set the value for all clients. Replicates automatically. ]]
function ValueState:set(value: any)
	local oldValue = self._value
	self._value = value
	
	-- Replicate to all clients
	self._dispatcher:fireAllClients(value)
	
	-- Notify server listeners
	if oldValue ~= value then
		self._dispatcher:fire(value, oldValue)
	end
end

--[[ Get the current value. ]]
function ValueState:get(): any
	return self._value
end

--[[ Like connect(), but fires immediately with the current value. ]]
function ValueState:observe(callback: (any, any) -> ())
	task.defer(callback, self._value, nil)
	-- Subscribe to internal local signal
	local connection = self._dispatcher:connect(function(value, oldValue)
		callback(value, oldValue)
	end)
	return function()
		connection:disconnect()
	end
end

--[[ Destroy the ValueState. ]]
function ValueState:destroy()
	self._dispatcher:destroy()
end

return ValueState
