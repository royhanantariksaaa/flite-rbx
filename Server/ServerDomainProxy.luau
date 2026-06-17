--[=[
	@module ServerDomainProxy
	@within Flite

	ServerDomainProxy (Shared/Server logic)
	Executes true authoritative Domain methods on the Server using 
	the real Server `services` environment.
]=]

local ServerDomainProxy = {}
local DomainBus = require(script.Parent.Parent.Shared.DomainBus)

--[=[
	Creates a server-side proxy used to call and observe a domain definition.
	@param domainDef domainDef: any
	@param getServiceFn Resolves service dependencies by name.
	@param getDomainFn Resolves domain dependencies by name.
	@return any
]=]
function ServerDomainProxy.new(domainDef: any, getServiceFn: (string) -> any, getDomainFn: (string) -> any)
	local proxy = {}
	
	-- We pass the true backend environment down to Domains on the Server.
	local serverSystem = {}
	setmetatable(serverSystem, {
		__index = function(_, key)
			if key == "emit" then
				return function(eventName: string, payload: any?)
					DomainBus.emit(domainDef.Name, eventName, payload)
				end
			end
			if key == "on" then
				return function(eventName: string, callback: (any?) -> ())
					return DomainBus.on(domainDef.Name, eventName, callback)
				end
			end

			-- Can be either a fully loaded backend Service, or another Domain.
			local svc = getServiceFn(key)
			if svc then return svc end
			
			local dom = getDomainFn(key)
			if dom then return dom end
			
			error(`[Framework.ServerDomainProxy] Failed to resolve dependency '{key}' in Server Domain`)
		end
	})
	
	-- Bind the exact pure logic functions from the Domain Definition
	-- but inject `serverSystem` as the first argument, which allows the Domain
	-- to seamlessly interact with backend-only logic!
	for methodName, data in domainDef._exposedMethods do
		proxy[methodName] = function(_, player, ...)
			return data.fn(serverSystem, player, ...)
		end
	end

--[=[
	Emits a local domain event to listeners on the client.
	@param eventName eventName: string
	@param payload payload: any?
]=]
	function proxy:emit(eventName: string, payload: any?)
		DomainBus.emit(domainDef.Name, eventName, payload)
	end

--[=[
	Subscribes to a local domain event.
	@param eventName eventName: string
	@param callback Receives the event payload.
	@return () -> ()
]=]
	function proxy:on(eventName: string, callback: (any?) -> ())
		return DomainBus.on(domainDef.Name, eventName, callback)
	end
	
	-- Expose configuration to init.luau validation checks
	proxy._exposedMethods = {}
	for methodName, data in domainDef._exposedMethods do
		proxy._exposedMethods[methodName] = data.config
	end
	
	return proxy
end

return ServerDomainProxy
