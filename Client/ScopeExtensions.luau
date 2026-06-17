--!optimize 2
--[=[
	@module ScopeExtensions
	@within Flite

	ScopeExtensions
	Adds composable hooks to a Weave scope for use inside Framework.createController.
	All connections are automatically cleaned up when the scope is destroyed
	via scope:OnDestroy().

	Available hooks:
		scope:useKey(keyCode, onPressed, onReleased?) -- Keyboard input binding
		scope:useButton(keyCode, onPressed, onReleased?) -- Gamepad button binding
		scope:useCharacter(player, onAdded, onRemoving?) -- Player character observer
		scope:useLocalCharacter(onAdded, onRemoving?) -- LocalPlayer character observer
		scope:usePlayers(callback) -- Player join/leave observer
		scope:useTheme(preset) -- Apply WeaveKit theme
		scope:useWaitFor(bindableName, timeout) -- Wait for BindableEvent before proceeding
]=]

local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ScopeExtensions = {}

local keyBindings = {}
local buttonBindings = {}
local activeKeyBindings = {}
local activeButtonBindings = {}
local inputBeganConnection = nil
local inputEndedConnection = nil

local function hasAnyBindings()
	for _, listeners in pairs(keyBindings) do
		if next(listeners) ~= nil then
			return true
		end
	end
	for _, listeners in pairs(buttonBindings) do
		if next(listeners) ~= nil then
			return true
		end
	end
	return false
end

local function removeBinding(bindingMap, activeMap, keyCode, binding)
	local listeners = bindingMap[keyCode]
	if listeners then
		listeners[binding] = nil
		if next(listeners) == nil then
			bindingMap[keyCode] = nil
		end
	end

	local activeListeners = activeMap[keyCode]
	if activeListeners then
		activeListeners[binding] = nil
		if next(activeListeners) == nil then
			activeMap[keyCode] = nil
		end
	end
end

local function cleanupInputHandlingIfIdle()
	if hasAnyBindings() then
		return
	end

	if inputBeganConnection then
		inputBeganConnection:Disconnect()
		inputBeganConnection = nil
	end
	if inputEndedConnection then
		inputEndedConnection:Disconnect()
		inputEndedConnection = nil
	end

	table.clear(activeKeyBindings)
	table.clear(activeButtonBindings)
end

local function getBindingTables(input: InputObject)
	if input.UserInputType == Enum.UserInputType.Keyboard then
		return keyBindings, activeKeyBindings
	end
	if string.find(input.UserInputType.Name, "Gamepad") then
		return buttonBindings, activeButtonBindings
	end

	return nil, nil
end

local function dispatchInputBegan(bindingMap, activeMap, keyCode: Enum.KeyCode)
	local listeners = bindingMap[keyCode]
	if not listeners then
		return
	end

	local activeListeners = activeMap[keyCode]
	if not activeListeners then
		activeListeners = {}
		activeMap[keyCode] = activeListeners
	end

	for binding in pairs(listeners) do
		activeListeners[binding] = (activeListeners[binding] or 0) + 1
		if binding.onPressed then
			task.spawn(binding.onPressed)
		end
	end
end

local function dispatchInputEnded(activeMap, keyCode: Enum.KeyCode)
	local activeListeners = activeMap[keyCode]
	if not activeListeners then
		return
	end

	for binding, activeCount in pairs(activeListeners) do
		if activeCount <= 1 then
			activeListeners[binding] = nil
			if binding.onReleased then
				task.spawn(binding.onReleased)
			end
		else
			activeListeners[binding] = activeCount - 1
		end
	end

	if next(activeListeners) == nil then
		activeMap[keyCode] = nil
	end
end

local function lazyInitInputHandling()
	if inputBeganConnection and inputEndedConnection then
		return
	end

	inputBeganConnection = UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end

		local bindingMap, activeMap = getBindingTables(input)
		if bindingMap and activeMap then
			dispatchInputBegan(bindingMap, activeMap, input.KeyCode)
		end
	end)

	inputEndedConnection = UserInputService.InputEnded:Connect(function(input)
		local _, activeMap = getBindingTables(input)
		if activeMap then
			dispatchInputEnded(activeMap, input.KeyCode)
		end
	end)
end

local function resolvePlayerGui(timeout: number?): PlayerGui?
	local player = Players.LocalPlayer
	if not player then
		return nil
	end

	local existingGui = player:FindFirstChild("PlayerGui")
	if existingGui and existingGui:IsA("PlayerGui") then
		return existingGui
	end

	if timeout and timeout > 0 then
		local foundGui = player:WaitForChild("PlayerGui", timeout)
		if foundGui and foundGui:IsA("PlayerGui") then
			return foundGui
		end
	end

	return nil
end

local function observeCharacter(scope: any, player: Player, onAdded: (Model, Player) -> (), onRemoving: ((Model, Player) -> ())?)
	local currentCharacter = player.Character
	if currentCharacter then
		task.spawn(onAdded, currentCharacter, player)
	end

	scope:OnDestroy(player.CharacterAdded:Connect(function(character)
		task.spawn(onAdded, character, player)
	end))

	if onRemoving then
		scope:OnDestroy(player.CharacterRemoving:Connect(function(character)
			task.spawn(onRemoving, character, player)
		end))
	end
end

--[=[
	Bind all composable hooks onto a Weave scope.
	@param scope  A Weave.Scope() instance
]=]
function ScopeExtensions.bind(scope: any)
	scope.playerGui = resolvePlayerGui(nil)

	function scope:getPlayerGui(timeout: number?): PlayerGui?
		if scope.playerGui and scope.playerGui.Parent then
			return scope.playerGui
		end

		local resolved = resolvePlayerGui(timeout)
		if resolved then
			scope.playerGui = resolved
		end
		return resolved
	end

	scope._onInit = nil
	scope._onStart = nil
	scope._onStop = nil
	scope._onHeartbeat = nil
	scope._onRenderStepped = nil

	function scope:onInit(callback: () -> ())
		scope._onInit = callback
	end

	function scope:onStart(callback: () -> ())
		scope._onStart = callback
	end

	function scope:onStop(callback: () -> ())
		scope._onStop = callback
	end

	function scope:onHeartbeat(callback: (number) -> ())
		scope._onHeartbeat = callback
	end

	function scope:onHeartbeatFixed(fixedDeltaTime: number, callback: (number) -> ())
		scope._onHeartbeat = {
			callback = callback,
			fixedDeltaTime = fixedDeltaTime,
		}
	end

	function scope:onRenderStepped(callback: (number) -> ())
		scope._onRenderStepped = callback
	end

	function scope:onRenderSteppedFixed(fixedDeltaTime: number, callback: (number) -> ())
		scope._onRenderStepped = {
			callback = callback,
			fixedDeltaTime = fixedDeltaTime,
		}
	end

	function scope:useKey(keyCode: Enum.KeyCode, onPressed: (() -> ())?, onReleased: (() -> ())?)
		lazyInitInputHandling()
		if not keyBindings[keyCode] then
			keyBindings[keyCode] = {}
		end

		local binding = {
			onPressed = onPressed,
			onReleased = onReleased,
		}
		keyBindings[keyCode][binding] = true

		scope:OnDestroy(function()
			removeBinding(keyBindings, activeKeyBindings, keyCode, binding)
			cleanupInputHandlingIfIdle()
		end)
	end

	function scope:useButton(keyCode: Enum.KeyCode, onPressed: (() -> ())?, onReleased: (() -> ())?)
		lazyInitInputHandling()
		if not buttonBindings[keyCode] then
			buttonBindings[keyCode] = {}
		end

		local binding = {
			onPressed = onPressed,
			onReleased = onReleased,
		}
		buttonBindings[keyCode][binding] = true

		scope:OnDestroy(function()
			removeBinding(buttonBindings, activeButtonBindings, keyCode, binding)
			cleanupInputHandlingIfIdle()
		end)
	end

	function scope:useCharacter(player: Player, onAdded: (Model, Player) -> (), onRemoving: ((Model, Player) -> ())?)
		if not player then
			return
		end

		observeCharacter(scope, player, onAdded, onRemoving)
	end

	function scope:useLocalCharacter(onAdded: (Model, Player) -> (), onRemoving: ((Model, Player) -> ())?)
		local localPlayer = Players.LocalPlayer
		if not localPlayer then
			warn("[Framework] useLocalCharacter could not resolve Players.LocalPlayer")
			return
		end

		observeCharacter(scope, localPlayer, onAdded, onRemoving)
	end

	function scope:usePlayers(callback: () -> ())
		task.spawn(callback)
		scope:OnDestroy(Players.PlayerAdded:Connect(function()
			callback()
		end))
		scope:OnDestroy(Players.PlayerRemoving:Connect(function()
			callback()
		end))
	end

	function scope:useTheme(preset: { [string]: any })
		local WeaveKit = require(ReplicatedStorage.Libraries.WeaveKit)
		WeaveKit.setTheme(preset)
	end

	function scope:useWaitFor(bindableName: string, timeout: number?)
		local bindable = ReplicatedStorage:WaitForChild(bindableName, timeout or 30)
		if bindable and bindable:IsA("BindableEvent") then
			bindable.Event:Wait()
		elseif bindable then
			warn(`[Framework] useWaitFor: "{bindableName}" is not a BindableEvent`)
		else
			warn(`[Framework] useWaitFor: "{bindableName}" not found within timeout`)
		end
	end
end

return ScopeExtensions
