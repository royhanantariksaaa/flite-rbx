--[[
	ControllerBuilder
	Instantiates scopes, hooks up ScopeExtensions, and tracks lifecycle 
	for Client Controllers.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ScopeExtensions = require(script.Parent.ScopeExtensions)
local Weave = require(ReplicatedStorage.Libraries.Weave)
local HookRegistration = require(script.Parent.Parent.Shared.HookRegistration)
local DependencyProxy = require(script.Parent.Parent.Shared.DependencyProxy)

local ControllerBuilder = {}

--[[
	Build a new Controller from a setup function.
]]
function ControllerBuilder.build(name: string, getControllerFn: (string) -> any, getServiceFn: (string) -> any, getDomainFn: (string) -> any, setupFn: (scope: any) -> ())
	-- Lazy load Weave to support testing injection if needed
	local scope = Weave.Scope()
	
	-- Attach our custom Weave extensions (usePlayers, onInit, onStart, etc.)
	ScopeExtensions.bind(scope)

	-- Add cleanup method that HookRegistration and other hooks expect
	function scope:AddCleanup(fn: () -> ())
		scope._trove:Add(fn)
	end

	-- Bind shared universal hooks
	HookRegistration.bind(scope, function(fn)
		scope:AddCleanup(fn)
	end)
	
	-- Initialize dependency tracker for Framework topological sorting
	scope._dependencies = {}
	
	function scope:useController(controllerName: string)
		if not table.find(scope._dependencies, controllerName) then
			table.insert(scope._dependencies, controllerName)
		end

		return DependencyProxy.create(
			controllerName,
			getControllerFn,
			`[Framework] Controller "{controllerName}" not found`
		)
	end

	-- Retrieve server-proxied services (lazy require to avoid cyclical deps)
	function scope:useService(serviceName: string)
		return DependencyProxy.create(
			serviceName,
			getServiceFn,
			`[Framework] Service "{serviceName}" not found`
		)
	end

	function scope:useServiceState(serviceRef: string | any, fieldName: string, callback: ((any, any) -> ())?)
		local serviceName = if type(serviceRef) == "string" then serviceRef else "<service>"
		local service = if type(serviceRef) == "string" then scope:useService(serviceRef) else serviceRef
		local state = service[fieldName]

		if type(state) ~= "table" or type(state.Get) ~= "function" then
			error(`[Framework] Service field "{serviceName}.{fieldName}" is not reactive state.`)
		end

		if type(callback) == "function" then
			scope:Observe(state, callback)
		end

		return state
	end

	-- Retrieve shared domains
	function scope:useDomain(domainName: string)
		return DependencyProxy.create(
			domainName,
			getDomainFn,
			`[Framework] Domain "{domainName}" not found`
		)
	end

	-- === CLIENT ONLY HOOKS ===
	function scope:useSound(soundId: string, props: {[string]: any}?)
		local snd = Instance.new("Sound")
		snd.SoundId = soundId
		snd.Parent = workspace.CurrentCamera
		if props then
			for k, v in props do snd[k] = v end
		end
		scope:AddCleanup(function() snd:Destroy() end)
		return {
			play = function() snd:Play() end,
			stop = function() snd:Stop() end,
			instance = snd
		}
	end

	-- Run the user's setup function
	setupFn(scope)
	
	-- Cleanup builder methods from scope to prevent pollution
	scope.useController = nil
	scope.useService = nil
	scope.useServiceState = nil
	scope.useDomain = nil
	
	-- Build the controller structure the framework relies on
	local controller = {
		Name = name,
		scope = scope,
		_dependencies = scope._dependencies,
		canParallelInit = scope.canParallelInit == true,
		_onInit = scope._onInit,
		_onStart = scope._onStart,
		_onStop = scope._onStop,
		_onHeartbeat = scope._onHeartbeat,
		_onRenderStepped = scope._onRenderStepped,
	}
	
	-- Expose scope methods on the controller table for cross-controller access
	for key, value in pairs(scope) do
		if type(key) == "string" and type(value) == "function" and controller[key] == nil then
			controller[key] = value
		end
	end
	
	return controller
end

function ControllerBuilder.initialize(controller: any)
	if controller._onInit then
		controller._onInit()
	end
end

function ControllerBuilder.finalize(controller: any)
	if controller._onStart then
		controller._onStart()
	end
end

return ControllerBuilder
