--!optimize 2
--[=[
	@module DomainBuilder
	@within Flite

	DomainBuilder (Shared)
	Constructs "Domains" - pure logic modules that run exactly the same 
	on both the Server and the Client.
	
	Crucially, a Domain CANNOT depend on Server Services or Client Controllers.
	It can only depend on other shared Domains.
]=]

local DependencyProxy = require(script.Parent.DependencyProxy)
local HookRegistration = require(script.Parent.HookRegistration)
local DomainBuilder = {}

--[=[
	Build a new Domain from a setup function.
	@param name               Domain name (e.g. "CombatDomain")
	@param getDomainFn        Callback to lazily fetch other Domains
	@param setupFn            Setup function that receives a context
	@return domain            The finalized domain table
]=]
function DomainBuilder.build(name: string, getDomainFn: (string) -> any, setupFn: (context: any) -> ())
	local context = {
		_dependencies = {},
		_exposedMethods = {},
		_cleanupCallbacks = {}
	}
	
	--[=[
		Declare a dependency on another Domain.
	]=]
	function context:useDependency(domainName: string)
		if not table.find(self._dependencies, domainName) then
			table.insert(self._dependencies, domainName)
		end

		return DependencyProxy.create(
			domainName,
			getDomainFn,
			`[Framework] Domain Dependency "{domainName}" could not be resolved.`
		)
	end
	
	--[=[
		Expose a method on the Domain.
		On the Server, these are callable directly.
		On the Client, these execute optimistically and then dispatch silently to the Server.
	]=]
	function context:expose(methodName: string, configOrFn: any, fn: any?)
		local conf
		local callback
		
		if type(configOrFn) == "function" then
			conf = {}
			callback = configOrFn
		else
			conf = configOrFn
			callback = fn
		end
		
		self._exposedMethods[methodName] = {
			config = conf,
			fn = callback
		}
	end

	-- Bind shared universal hooks
	HookRegistration.bind(context, function(fn)
		table.insert(context._cleanupCallbacks, fn)
	end)
	
	-- Run the setup function
	setupFn(context)
	-- Build the final domain table
	local domain = { Name = name }
	domain._dependencies = context._dependencies
	domain._exposedMethods = context._exposedMethods
	
	-- Note: The actual method execution mapping happens in ClientDomainProxy
	-- and ServerDomainProxy to handle the differing context environments.
	
	return domain
end

return DomainBuilder
