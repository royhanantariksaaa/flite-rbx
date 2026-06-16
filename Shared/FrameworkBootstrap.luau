--[[
	FrameworkBootstrap
	Handles FrameworkComm creation and runtime listener wiring.
]]

local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local NetworkDispatcher = require(script.Parent.NetworkDispatcher)

local FrameworkBootstrap = {}

local function setClientStateValue(stateValue: any, newValue: any): boolean
	if type(stateValue) ~= "table" then
		return false
	end

	if type(stateValue.set) == "function" then
		stateValue:set(newValue)
		return true
	end

	if type(stateValue.Set) == "function" then
		stateValue:Set(newValue)
		return true
	end

	return false
end

function FrameworkBootstrap.ensureFrameworkComm(): Folder
	local frameworkComm = ReplicatedStorage:FindFirstChild("FrameworkComm")
	if RunService:IsServer() and not frameworkComm then
		frameworkComm = Instance.new("Folder")
		frameworkComm.Name = "FrameworkComm"
		frameworkComm.Parent = ReplicatedStorage

		local stateEvent = Instance.new("RemoteEvent")
		stateEvent.Name = "StateEvent"
		stateEvent.Parent = frameworkComm

		local signalEvent = Instance.new("RemoteEvent")
		signalEvent.Name = "SignalEvent"
		signalEvent.Parent = frameworkComm

		local methodEvent = Instance.new("RemoteFunction")
		methodEvent.Name = "MethodEvent"
		methodEvent.Parent = frameworkComm

		local unreliableSignalEvent = Instance.new("UnreliableRemoteEvent")
		unreliableSignalEvent.Name = "UnreliableSignalEvent"
		unreliableSignalEvent.Parent = frameworkComm
	end

	if not frameworkComm then
		frameworkComm = ReplicatedStorage:WaitForChild("FrameworkComm", 10) :: Folder?
	end
	if not frameworkComm then
		error("[Framework] FrameworkComm is unavailable.")
	end
	return frameworkComm
end

function FrameworkBootstrap.attachServerNetwork(services: any, domains: any, frameworkComm: Folder)
	return NetworkDispatcher.initialize(services, domains, frameworkComm)
end

function FrameworkBootstrap.setManifestMode(frameworkComm: Folder, manifestOnly: boolean?)
	frameworkComm:SetAttribute("_manifestOnly", manifestOnly == true)
end

function FrameworkBootstrap.attachClientListeners(services: any, frameworkComm: Folder)
	local ServiceProxy = require(script.Parent.Parent.Client.ServiceProxy)
	local stateEvent = frameworkComm:WaitForChild("StateEvent") :: RemoteEvent
	local signalEvent = frameworkComm:WaitForChild("SignalEvent") :: RemoteEvent
	local unreliableSignalEvent = frameworkComm:WaitForChild("UnreliableSignalEvent") :: UnreliableRemoteEvent

	local function routeClientSignal(serviceName, signalName, ...)
		if serviceName == "__FrameworkStream" and signalName == "Progress" then
			local requestId, payload = ...
			if type(requestId) == "string" then
				ServiceProxy.dispatchStreamProgress(requestId, payload)
			end
			return
		end

		local proxy = services[serviceName]
		if proxy and proxy[signalName] and type(proxy[signalName]._dispatch) == "function" then
			proxy[signalName]:_dispatch(...)
		end
	end

	local stateConnection = stateEvent.OnClientEvent:Connect(function(serviceName, fieldName, newValue)
		local proxy = services[serviceName]
		if proxy then
			local stateValue = rawget(proxy, fieldName)
			if stateValue and not setClientStateValue(stateValue, newValue) then
				warn(`[Framework] Received state update for {serviceName}.{fieldName}, but the client state object is not writable.`)
			end
		end
	end)

	local signalConnection = signalEvent.OnClientEvent:Connect(routeClientSignal)
	local unreliableSignalConnection = unreliableSignalEvent.OnClientEvent:Connect(routeClientSignal)

	return function()
		stateConnection:Disconnect()
		signalConnection:Disconnect()
		unreliableSignalConnection:Disconnect()
	end
end

return FrameworkBootstrap
