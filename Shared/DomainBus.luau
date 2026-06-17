--!native
--!optimize 2
--[=[
	@module DomainBus
	@within Flite

	Local event bus for shared domain events.
]=]

local Signal = require(game:GetService("ReplicatedStorage").Libraries.Echo)

local DomainBus = {}

local buses = {}

local function getKey(domainName: string, eventName: string): string
	return `{domainName}::{eventName}`
end

local function getSignal(domainName: string, eventName: string)
	local key = getKey(domainName, eventName)
	local existing = buses[key]
	if existing then
		return existing
	end

	local created = Signal.new()
	buses[key] = created
	return created
end

--[=[
	Emit a local event for a shared domain.

	@param domainName string -- domain namespace
	@param eventName string -- event name within the domain
	@param payload any? -- optional event payload
]=]
function DomainBus.emit(domainName: string, eventName: string, payload: any?)
	getSignal(domainName, eventName):fire(payload)
end

--[=[
	Subscribe to a local event for a shared domain.

	@param domainName string -- domain namespace
	@param eventName string -- event name within the domain
	@param callback (any?) -> () -- called with the emitted payload
	@return RBXScriptConnection -- disconnect to unsubscribe
]=]
function DomainBus.on(domainName: string, eventName: string, callback: (any?) -> ())
	return getSignal(domainName, eventName):connect(callback)
end

return DomainBus
