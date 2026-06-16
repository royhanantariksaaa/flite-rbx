local Signal = require(game:GetService("ReplicatedStorage").Libraries.WeaveSignal)

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

function DomainBus.emit(domainName: string, eventName: string, payload: any?)
	getSignal(domainName, eventName):fire(payload)
end

function DomainBus.on(domainName: string, eventName: string, callback: (any?) -> ())
	return getSignal(domainName, eventName):connect(callback)
end

return DomainBus
