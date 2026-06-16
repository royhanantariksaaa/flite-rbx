local FrameworkSignal = require(script.Parent.Parent.FrameworkSignal)
local MessagingService = game:GetService("MessagingService")
local Echo = require(game:GetService("ReplicatedStorage").Libraries.Echo)

local SignalRegistration = {}

function SignalRegistration.bind(context: any, config: any)
	local function registerSignal(selfRef: any, eventRef: any, nameOrTable: string | { string }, schemas: { any }?)
		if type(nameOrTable) == "table" then
			local result = {}
			for _, signalName in nameOrTable do
				config.validateFieldName(signalName)
				local sig = FrameworkSignal.new(eventRef, config.serviceName, signalName)
				sig._schema = schemas
				selfRef._signals[signalName] = sig
				selfRef[signalName] = sig
				result[signalName] = sig
			end
			return result
		end

		local signalName = nameOrTable :: string
		config.validateFieldName(signalName)
		local sig = FrameworkSignal.new(eventRef, config.serviceName, signalName)
		sig._schema = schemas
		selfRef._signals[signalName] = sig
		selfRef[signalName] = sig
		return sig
	end

	function context:useSignal(nameOrTable: string | { string }, schemas: { any }?)
		return registerSignal(self, config.globalSignalEvent, nameOrTable, schemas)
	end

	function context:useUnreliableSignal(nameOrTable: string | { string }, schemas: { any }?)
		return registerSignal(self, config.globalUnreliableSignalEvent, nameOrTable, schemas)
	end

	function context:useGlobalSignal(nameStr: string)
		config.validateFieldName(nameStr)
		local globalKey = config.serviceName .. "_" .. nameStr
		local localSignal = Echo.new()

		local subscription = MessagingService:SubscribeAsync(globalKey, function(message)
			local payload = message.Data
			localSignal:fire(table.unpack(payload, 1, payload.n or #payload))
		end)
		table.insert(self._cleanupCallbacks, function()
			subscription:Disconnect()
			localSignal:destroy()
		end)

		local signal = {
			fire = function(_, ...)
				local args = table.pack(...)
				pcall(function()
					MessagingService:PublishAsync(globalKey, args)
				end)
			end,
			connect = function(_, fn: (...any) -> ())
				return localSignal:connect(fn)
			end,
		}

		self._signals[nameStr] = signal
		self[nameStr] = signal
		return signal
	end
end

return SignalRegistration
