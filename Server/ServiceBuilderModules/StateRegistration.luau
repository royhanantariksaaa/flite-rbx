--[=[
	@module StateRegistration
	@within Flite

	Binds server state constructors onto service contexts.
]=]

local MapState = require(script.Parent.Parent.MapState)
local ValueState = require(script.Parent.Parent.ValueState)
local ChannelState = require(script.Parent.Parent.ChannelState)
local ComputedState = require(script.Parent.Parent.ComputedState)
local GlobalValueState = require(script.Parent.Parent.GlobalValueState)

local StateRegistration = {}

--[=[
	Installs state registration methods on a service builder context.
	@param context context: any
	@param config config: any
]=]
function StateRegistration.bind(context: any, config: any)
	local function registerState(
		selfRef: any,
		nameOrTable: string | { [string]: any },
		defaultValue: any?,
		createState: (string, any?) -> any
	)
		if type(nameOrTable) == "table" then
			local result = {}
			for fieldName, fieldDefault in nameOrTable do
				config.validateFieldName(fieldName)
				local state = createState(fieldName, fieldDefault)
				selfRef._states[fieldName] = state
				selfRef[fieldName] = state
				result[fieldName] = state
			end
			return result
		end

		local fieldName = nameOrTable :: string
		config.validateFieldName(fieldName)
		local state = createState(fieldName, defaultValue)
		selfRef._states[fieldName] = state
		selfRef[fieldName] = state
		return state
	end

	function context:useMapState(nameOrTable: string | { [string]: any }, default: any?)
		return registerState(self, nameOrTable, default, function(fieldName, fieldDefault)
			return MapState.new(config.globalStateEvent, config.serviceName, fieldName, fieldDefault)
		end)
	end

	function context:useValueState(nameOrTable: string | { [string]: any }, default: any?)
		return registerState(self, nameOrTable, default, function(fieldName, fieldDefault)
			return ValueState.new(config.globalStateEvent, config.serviceName, fieldName, fieldDefault)
		end)
	end

	function context:useChannelState(nameOrTable: string | { [string]: any }, default: any?)
		return registerState(self, nameOrTable, default, function(fieldName, fieldDefault)
			return ChannelState.new(config.globalStateEvent, config.serviceName, fieldName, fieldDefault)
		end)
	end

	function context:useComputedState(
		fieldName: string,
		dependencies: { any },
		computeFn: (...any) -> any,
		options: { replicate: boolean? }?
	)
		config.validateFieldName(fieldName)
		local state = ComputedState.new(config.globalStateEvent, config.serviceName, fieldName, dependencies, computeFn, options)
		self._states[fieldName] = state
		self[fieldName] = state
		return state
	end

	function context:useGlobalValue(nameStr: string, default: any?)
		config.validateFieldName(nameStr)
		local state = GlobalValueState.new(config.globalStateEvent, config.serviceName, nameStr, default)
		self._states[nameStr] = state
		self[nameStr] = state
		return state
	end
end

return StateRegistration
