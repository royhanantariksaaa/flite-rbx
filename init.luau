--!optimize 2
--[=[
	@module Flite
	@class Flite

	A composable hooks-based game framework for Roblox, built on Weave.
	The entry point exposes service, controller, and domain registration,
	startup orchestration, schema contracts, permission helpers, and structured
	error utilities.

	Public API surface (all available on the returned `Flite` table):

	- **Registration**: `Flite.createService`, `Flite.createController`,
	  `Flite.createDomain`, `Flite.loadModules`
	- **Runtime**: `Flite.configure`, `Flite.start`, `Flite.stop`
	- **Client proxies**: `Flite.getService`, `Flite.getDomain`
	- **Validation & permissions**: `Flite.contract`, `Flite.perm`
	- **Errors & cancellation**: `Flite.error`, `Flite.Errors`,
	  `Flite.CancelToken`

	```lua
	local Flite = require(ReplicatedStorage.Libraries.Flite)

	Flite.createService("PlotService", function(self)
		local plots = self:useMapState("playerPlots", nil)
		self:onPlayerAdded(function(player)
			plots:set(player, {})
		end)
	end)
	```
]=]

local RunService = game:GetService("RunService")
local FrameworkBootstrap = require(script.Shared.FrameworkBootstrap)
local CancelToken = require(script.Shared.CancelToken)
local FrameworkError = require(script.Shared.FrameworkError)
local PermissionPolicy = require(script.Shared.PermissionPolicy)
local FrameworkComm = FrameworkBootstrap.ensureFrameworkComm()

--[=[
	@class Signal

	A pub/sub signal for server-client and server-server events.
	Created via `self:useSignal()` or `self:useUnreliableSignal()`.

	```lua
	local signal = self:useSignal("playerDied")
	signal:connect(function(player)
		print(player.Name, "died")
	end)
	signal:fireAllClients(player)
	```
]=]
export type Signal = {
	--[=[
		Fire to local server listeners only. Does NOT cross the network.
	]=]
	fire: (self: Signal, ...any) -> (),
	--[=[
		Fire to a specific client via the global RemoteEvent.
	]=]
	fireClient: (self: Signal, player: Player, ...any) -> (),
	--[=[
		Broadcast to ALL connected clients.
	]=]
	fireAllClients: (self: Signal, ...any) -> (),
	--[=[
		Fire to one client AND local server listeners.
	]=]
	fireClientAndLocal: (self: Signal, player: Player, ...any) -> (),
	--[=[
		Broadcast to ALL clients AND local server listeners.
	]=]
	fireAll: (self: Signal, ...any) -> (),
	--[=[
		Subscribe to this signal. Returns an RBXScriptConnection.
	]=]
	connect: (self: Signal, callback: (...any) -> ()) -> RBXScriptConnection,
	--[=[
		Subscribe once. Auto-disconnects after the first fire.
	]=]
	once: (self: Signal, callback: (...any) -> ()) -> RBXScriptConnection,
	--[=[
		Yield the calling thread until this signal fires. Returns the fired args.
	]=]
	wait: (self: Signal) -> (...any),
	--[=[
		Destroy the signal and disconnect all listeners.
	]=]
	destroy: (self: Signal) -> (),
}

--[=[
	@class MapState

	Keyed reactive state. Each key (typically a Player, but any key works)
	has its own value. Replicates automatically to clients. Created via
	`self:useMapState()`.

	```lua
	local coins = self:useMapState("coins", 0)
	coins:set(player, 100)
	coins:get(player) -- 100
	```
]=]
export type MapState<V> = {
	isState: boolean,
	--[=[
		Set the fallback value for ALL unassigned keys.
	]=]
	setDefault: (self: MapState<V>, defaultValue: V) -> (),
	--[=[
		Set a value for a specific key (commonly a Player, but any key is allowed).
	]=]
	set: (self: MapState<V>, key: any, value: V) -> (),
	--[=[
		Set a value for all keys whose current value passes `predicate`.
	]=]
	setFilter: (self: MapState<V>, predicate: (key: any, value: V) -> boolean, value: V) -> (),
	--[=[
		Get the current value for a key. Returns the fallback default if unset.
	]=]
	get: (self: MapState<V>, key: any) -> V,
	--[=[
		Returns a generic-for iterator triple over all active keys and their
		current values. Use as `for key, value in state:getEach() do`.
	]=]
	getEach: (self: MapState<V>) -> ((any, any) -> (any, V), any, any),
	--[=[
		Clear a specific key. It reverts to the fallback default.
	]=]
	clear: (self: MapState<V>, key: any) -> (),
	--[=[
		Clear ALL keys. Everything reverts to the fallback default.
	]=]
	clearAll: (self: MapState<V>) -> (),
	--[=[
		Observe a specific key's value. Fires immediately, then on changes. Returns a cleanup function.
	]=]
	observe: (self: MapState<V>, key: any, callback: (newValue: V, oldValue: V) -> ()) -> () -> (),
	--[=[
		Cleanup the MapState and disconnect all connections.
	]=]
	destroy: (self: MapState<V>) -> (),
	--[=[
		Fire to local server listeners only (inherited from Signal).
	]=]
	fire: (self: MapState<V>, newValue: V, oldValue: V, key: any?) -> (),
	--[=[
		Fire to a specific client (inherited from Signal).
	]=]
	fireClient: (self: MapState<V>, player: Player, value: V) -> (),
	--[=[
		Broadcast to all clients (inherited from Signal).
	]=]
	fireAllClients: (self: MapState<V>, value: V) -> (),
	--[=[
		Subscribe to changes on any key.
	]=]
	connect: (self: MapState<V>, callback: (newValue: V, oldValue: V, key: any?) -> ()) -> RBXScriptConnection,
	--[=[
		Subscribe once (inherited from Signal).
	]=]
	once: (self: MapState<V>, callback: (newValue: V, oldValue: V, key: any?) -> ()) -> RBXScriptConnection,
	--[=[
		Wait for next change (inherited from Signal).
	]=]
	wait: (self: MapState<V>) -> (V, V, any?),
}

--[=[
	@class ValueState

	Global reactive state (scalar). One value shared across all clients.
	Replicates automatically. Created via `self:useValueState()`.

	```lua
	local gameState = self:useValueState("gameState", "lobby")
	gameState:set("playing")
	gameState:get() -- "playing"
	```
]=]
export type ValueState<V> = {
	isState: boolean,
	--[=[
		Set the value for all clients. Replicates automatically.
	]=]
	set: (self: ValueState<V>, value: V) -> (),
	--[=[
		Get the current value.
	]=]
	get: (self: ValueState<V>) -> V,
	--[=[
		Observe changes. Fires immediately with the current value, then on each change. Returns a cleanup function.
	]=]
	observe: (self: ValueState<V>, callback: (newValue: V, oldValue: V) -> ()) -> () -> (),
	--[=[
		Cleanup the ValueState and disconnect all connections.
	]=]
	destroy: (self: ValueState<V>) -> (),
	--[=[
		Fire to local server listeners only (inherited from Signal).
	]=]
	fire: (self: ValueState<V>, newValue: V, oldValue: V) -> (),
	--[=[
		Fire to a specific client (inherited from Signal).
	]=]
	fireClient: (self: ValueState<V>, player: Player, value: V) -> (),
	--[=[
		Broadcast to all clients (inherited from Signal).
	]=]
	fireAllClients: (self: ValueState<V>, value: V) -> (),
	--[=[
		Subscribe to value changes.
	]=]
	connect: (self: ValueState<V>, callback: (newValue: V, oldValue: V) -> ()) -> RBXScriptConnection,
	--[=[
		Subscribe once (inherited from Signal).
	]=]
	once: (self: ValueState<V>, callback: (newValue: V, oldValue: V) -> ()) -> RBXScriptConnection,
	--[=[
		Wait for next change (inherited from Signal).
	]=]
	wait: (self: ValueState<V>) -> (V, V),
}

--[=[
	@class ChannelState

	Targeted reactive state. Only players who subscribe receive updates.
	Useful for inventory, quests, or other opt-in data.
	Created via `self:useChannelState()`.

	```lua
	local inventory = self:useChannelState("inventory", {})
	inventory:subscribe(player)
	inventory:set({ sword = 1 })
	```
]=]
export type ChannelState<V> = {
	isState: boolean,
	--[=[
		Subscribe a player to receive updates. Sends the current value immediately.
	]=]
	subscribe: (self: ChannelState<V>, player: Player) -> (),
	--[=[
		Unsubscribe a player from receiving updates.
	]=]
	unsubscribe: (self: ChannelState<V>, player: Player) -> (),
	--[=[
		Returns an array of currently subscribed players.
	]=]
	getSubscribers: (self: ChannelState<V>) -> { Player },
	--[=[
		Set the value. Replicates ONLY to subscribed clients.
	]=]
	set: (self: ChannelState<V>, value: V) -> (),
	--[=[
		Get the current value.
	]=]
	get: (self: ChannelState<V>, player: Player?) -> V,
	--[=[
		Observe changes on the server. Fires immediately, then on each change. Returns a cleanup function.
	]=]
	observe: (self: ChannelState<V>, callback: (newValue: V, oldValue: V) -> ()) -> () -> (),
	--[=[
		Cleanup the ChannelState and disconnect all connections.
	]=]
	destroy: (self: ChannelState<V>) -> (),
	--[=[
		Fire to local server listeners only (inherited from Signal).
	]=]
	fire: (self: ChannelState<V>, newValue: V, oldValue: V) -> (),
	--[=[
		Fire to a specific client (inherited from Signal).
	]=]
	fireClient: (self: ChannelState<V>, player: Player, value: V) -> (),
	--[=[
		Broadcast to all clients (inherited from Signal).
	]=]
	fireAllClients: (self: ChannelState<V>, value: V) -> (),
	--[=[
		Subscribe to changes (inherited from Signal).
	]=]
	connect: (self: ChannelState<V>, callback: (newValue: V, oldValue: V) -> ()) -> RBXScriptConnection,
	--[=[
		Subscribe once (inherited from Signal).
	]=]
	once: (self: ChannelState<V>, callback: (newValue: V, oldValue: V) -> ()) -> RBXScriptConnection,
	--[=[
		Wait for next change (inherited from Signal).
	]=]
	wait: (self: ChannelState<V>) -> (V, V),
}

--[=[
	@class ComputedState

	Derives a reactive value from one or more dependencies (ValueState, MapState, or other ComputedState).
	Automatically recalculates when any dependency changes.
	Created via `self:useComputedState()`.

	```lua
	local totalPower = self:useComputedState("totalPower", { weaponPower, buffMultiplier }, function(weapon, buff)
		return weapon * buff
	end, { replicate = true })
	```
]=]
export type ComputedState<V> = {
	isState: boolean,
	--[=[
		Get the current computed value for a key (or nil for global scalar).
	]=]
	get: (self: ComputedState<V>, key: any?) -> V,
	--[=[
		Observe computed changes. Fires immediately, then on recalculation. Returns a cleanup function.
	]=]
	observe: (self: ComputedState<V>, key: any?, callback: (newValue: V, oldValue: V) -> ()) -> () -> (),
	--[=[
		Cleanup the ComputedState and disconnect all connections.
	]=]
	destroy: (self: ComputedState<V>) -> (),
}

--[=[
	@class GlobalValueState

	Synchronizes a single value across all servers in an experience using
	MemoryStoreService (atomic updates) and MessagingService (fast replication).
	Created via `self:useGlobalValue()`.

	```lua
	local serverCount = self:useGlobalValue("serverCount", 0)
	serverCount:update(function(current) return current + 1 end)
	```
]=]
export type GlobalValueState<V> = {
	isState: boolean,
	--[=[
		Get the current value.
	]=]
	get: (self: GlobalValueState<V>) -> V,
	--[=[
		Set the value. Wraps update() internally for atomic cross-server sync.
	]=]
	set: (self: GlobalValueState<V>, value: V) -> (),
	--[=[
		Atomic UpdateAsync wrapper. Pass a transform function that receives the
		current value and returns the new one. Returns the raw UpdateAsync
		result (which may include the store's metadata).
	]=]
	update: (self: GlobalValueState<V>, transformFn: (current: V) -> V) -> any,
	--[=[
		Observe changes. Fires immediately, then on each change. Returns a cleanup function.
	]=]
	observe: (self: GlobalValueState<V>, callback: (newValue: V, oldValue: V) -> ()) -> () -> (),
	--[=[
		Cleanup the GlobalValueState and disconnect all connections.
	]=]
	destroy: (self: GlobalValueState<V>) -> (),
}

--[=[
	@class Service

	A server-side service. Created via `Flite.createService()`.
	Services manage state, signals, lifecycle events, persistence, and exposed methods.

	```lua
	local PlotService = Flite.createService("PlotService", function(self: Flite.Service)
		self:useMapState("playerPlots")
		self:onPlayerAdded(function(player)
			self.playerPlots:set(player, { owned = false })
		end)
	end)
	```
]=]
export type Service = {
	--[=[
		The name of this service.
	]=]
	Name: string,
	--[=[
		Create per-player reactive state. Each player gets their own value.
		Pass a string to create one state, or a table `{ fieldName = defaultValue }` to create many.

		```lua
		self:useMapState("playerPlots")
		self:useMapState({ coins = 0, level = 1 })
		```
	]=]
	useMapState: ((self: Service, name: string, defaultValue: any?) -> MapState<any>) & ((self: Service, states: { [string]: any }, defaultValue: any?) -> { [string]: MapState<any> }),
	--[=[
		Create global reactive state (scalar). One value shared across all clients.

		```lua
		self:useValueState("gameState", "lobby")
		self:useValueState({ score = 0, timer = 0 })
		```
	]=]
	useValueState: ((self: Service, name: string, defaultValue: any?) -> ValueState<any>) & ((self: Service, states: { [string]: any }, defaultValue: any?) -> { [string]: ValueState<any> }),
	--[=[
		Create targeted reactive state. Only subscribed players receive updates.

		```lua
		self:useChannelState("inventory")
		```
	]=]
	useChannelState: ((self: Service, name: string, defaultValue: any?) -> ChannelState<any>) & ((self: Service, states: { [string]: any }, defaultValue: any?) -> { [string]: ChannelState<any> }),
	--[=[
		Create a computed state derived from other state objects.
		Set `options.replicate = true` to replicate the computed value to clients.

		```lua
		self:useComputedState("totalPower", { weaponPower, buffMultiplier }, function(weapon, buff)
			return weapon * buff
		end, { replicate = true })
		```
	]=]
	useComputedState: (self: Service, name: string, dependencies: { any }, computeFn: (...any) -> any, options: { replicate: boolean? }?) -> ComputedState<any>,
	--[=[
		Create cross-server synchronized state using MemoryStoreService + MessagingService.

		```lua
		self:useGlobalValue("globalLeaderboard")
		```
	]=]
	useGlobalValue: (self: Service, name: string, defaultValue: any?) -> GlobalValueState<any>,
	--[=[
		Create a reliable signal for server-client and server-server events.
		Optionally pass schemas for compressed network transmission.

		```lua
		self:useSignal("playerDied")
		self:useSignal({ "playerDied", "playerJoined" })
		```
	]=]
	useSignal: ((self: Service, name: string, schema: { any }?) -> Signal) & ((self: Service, names: { string }, schema: { any }?) -> { [string]: Signal }),
	--[=[
		Create an unreliable signal (uses UnreliableRemoteEvent). Faster but may drop packets.
		Best for high-frequency events like position updates.

		```lua
		self:useUnreliableSignal("positionUpdate")
		```
	]=]
	useUnreliableSignal: ((self: Service, name: string, schema: { any }?) -> Signal) & ((self: Service, names: { string }, schema: { any }?) -> { [string]: Signal }),
	--[=[
		Create a global signal shared across all services. Useful for cross-service communication.

		```lua
		self:useGlobalSignal("serverAnnouncement")
		```
	]=]
	useGlobalSignal: (self: Service, name: string) -> { fire: (self: any, ...any) -> (), connect: (self: any, callback: (...any) -> ()) -> RBXScriptConnection },
	--[=[
		Register an init callback. Runs once when the service is initialized (before start).
	]=]
	onInit: (self: Service, callback: () -> ()) -> (),
	--[=[
		Register a callback that runs before the server shuts down.
	]=]
	beforeServerShutdown: (self: Service, callback: (reason: string?) -> ()) -> (),
	--[=[
		Register a start callback. Runs once after init, when all services are ready.
	]=]
	onStart: (self: Service, callback: () -> ()) -> (),
	--[=[
		Register a stop callback. Runs when the service is stopped/destroyed.
	]=]
	onStop: (self: Service, callback: () -> ()) -> (),
	--[=[
		Register a callback for when a player joins the game.
	]=]
	onPlayerAdded: (self: Service, callback: (player: Player) -> ()) -> (),
	--[=[
		Register a callback for when a player leaves the game.
	]=]
	onPlayerRemoving: (self: Service, callback: (player: Player) -> ()) -> (),
	--[=[
		Register a callback for when a player's character spawns.
	]=]
	onPlayerSpawned: (self: Service, callback: (player: Player, character: Model) -> ()) -> (),
	--[=[
		Register a callback for when a player's character is removed.
	]=]
	onPlayerDespawned: (self: Service, callback: (player: Player, character: Model) -> ()) -> (),
	--[=[
		Register a callback that runs every frame (RunService.Heartbeat).
	]=]
	onHeartbeat: (self: Service, callback: (deltaTime: number) -> ()) -> (),
	onHeartbeatFixed: (self: Service, fixedDeltaTime: number, callback: (deltaTime: number) -> ()) -> (),
	--[=[
		Wire up persistent storage for state fields.
		If no fields specified, all state fields are persisted.

		```lua
		self:usePersistent(DataStoreService, { "playerPlots", "coins" })
		```
	]=]
	usePersistent: (self: Service, dataStoreService: any, fields: { string }?) -> (),
	--[=[
		Register a callback for when a player's data is loaded and ready.
	]=]
	onPlayerReady: (self: Service, callback: (profile: any, player: Player, data: { [string]: any }) -> ()) -> (),
	--[=[
		Register a callback for when a player's session ends (leave or server shutdown).
	]=]
	onPlayerSessionEnd: (self: Service, callback: (profile: any, player: Player, data: { [string]: any }, reason: string?) -> ()) -> (),
	--[=[
		Register middleware for exposed methods. Return `true` to allow, `false` to block.

		```lua
		self:useMiddleware(function(player, method, ...)
			return player.UserId > 0
		end)
		```
	]=]
	useMiddleware: (self: Service, callback: (player: Player, method: string, ...any) -> boolean) -> (),
	--[=[
		Expose methods that clients can call remotely.

		```lua
		self:expose("buyItem")
		self:expose({ "buyItem", "sellItem" })
		```
	]=]
	expose: (self: Service, method: string | { string }, callback: any?) -> (),
	--[=[
		Declare a dependency on another service. Returns a proxy to that service.

		```lua
		local InventoryService = self:useDependency("InventoryService")
		```
	]=]
	useDependency: (self: Service, serviceName: string) -> any,
	--[=[
		Schedule a function to run after a delay.
	]=]
	useTimeout: (self: Service, fn: () -> (), delayMs: number) -> thread,
	--[=[
		Schedule a function to run repeatedly at an interval.
	]=]
	useInterval: (self: Service, fn: () -> (), intervalMs: number) -> thread,
	--[=[
		Create and manage a Tween.
	]=]
	useTween: (self: Service, target: any, info: TweenInfo, goals: {[string]: any}, callback: (() -> ())?) -> { Cancel: () -> (), OnMarker: (number, () -> ()) -> any },
	--[=[
		Debounce a function call.
	]=]
	useDebounce: <T...>(self: Service, fn: (T...) -> (), delayMs: number) -> (T...) -> (),
	--[=[
		Throttle a function call.
	]=]
	useThrottle: <T...>(self: Service, fn: (T...) -> (), intervalMs: number) -> (T...) -> (),
	--[=[
		Create a mutable ref object.
	]=]
	useRef: <T>(self: Service, initialValue: T?) -> { current: T? },
	--[=[
		Memoize a computation based on dependencies.
	]=]
	useMemo: <T>(self: Service, fn: () -> T, dependencies: {any}) -> () -> T,
	--[=[
		Run side effects when dependencies change.
	]=]
	useEffect: (self: Service, fn: () -> (() -> ())?, dependencies: {any}) -> () -> (),
	--[=[
		Batch multiple updates together.
	]=]
	useBatch: (self: Service, waitMs: number) -> ((() -> ()) -> ()),
	--[=[
		Create a rollback state for temporary changes.
	]=]
	useRollback: (self: Service, state: any, restoreValue: any) -> (() -> ()),
	--[=[
		Create a spring animation.
	]=]
	useSpring: (self: Service, initialValue: number, stiffness: number?, damping: number?) -> { set: (number) -> (), get: () -> number, immediate: (number) -> () },
	--[=[
		Create a cached resolver with TTL.
	]=]
	useCache: (self: Service, ttlMs: number, resolver: (...any) -> any) -> ((...any) -> any),
	--[=[
		Run a function only once per key.
	]=]
	useOnce: (self: Service, key: string, fn: () -> ()) -> (() -> ()),
	--[=[
		Get the previous value of a changing variable.
	]=]
	usePrevious: (self: Service, value: any) -> any,
	--[=[
		Create a raycast function.
	]=]
	useRaycast: (self: Service, params: RaycastParams?, trackPlayers: {Player}?) -> ((origin: Vector3, direction: Vector3, maxDistance: number?) -> RaycastResult?),
	--[=[
		Create a blockcast function.
	]=]
	useBlockcast: (self: Service, params: RaycastParams?, trackPlayers: {Player}?) -> ((size: Vector3, origin: Vector3, direction: Vector3, maxDistance: number?) -> RaycastResult?),
	--[=[
		Create a shapecast function.
	]=]
	useShapecast: (self: Service, shape: any, params: RaycastParams?, trackPlayers: {Player}?) -> ((cframe: CFrame, direction: Vector3, maxDistance: number?) -> RaycastResult?),
	--[=[
		Create a spherecast function.
	]=]
	useSpherecast: (self: Service, radius: number, params: RaycastParams?, trackPlayers: {Player}?) -> ((origin: Vector3, direction: Vector3, maxDistance: number?) -> RaycastResult?),
	--[=[
		Create a boxcast function.
	]=]
	useBoxcast: (self: Service, size: Vector3, params: RaycastParams?, trackPlayers: {Player}?) -> ((cframe: CFrame, direction: Vector3, maxDistance: number?) -> RaycastResult?),
	--[=[
		Create a touch detection function that fires on both enter and exit.
	]=]
	useTouched: (self: Service, target: Instance | () -> CFrame, radius: number?, params: OverlapParams?, trackPlayers: {Player}?) -> { Connect: ((callback: (otherPart: Instance, isEntering: boolean) -> ()) -> { Disconnect: () -> () }), Once: ((callback: (otherPart: Instance, isEntering: boolean) -> ()) -> { Disconnect: () -> () }), DisconnectAll: () -> () },
	--[=[
		Observe instances with a specific tag.
	]=]
	observeTag: (self: Service, tag: string, callback: (instance: Instance, isTagged: boolean) -> ()) -> (),
	--[=[
		Observe tagged instances with separate add/remove callbacks.
	]=]
	useTagged: (self: Service, tag: string, onAdded: (instance: Instance) -> (), onRemoved: ((instance: Instance) -> ())?) -> (),
	--[=[
		Get all instances with a specific tag.
	]=]
	getTagged: (self: Service, tag: string) -> {Instance},
	--[=[
		Check if an instance has a specific tag.
	]=]
	hasTag: (self: Service, instance: Instance, tag: string) -> boolean,
	-- Allow custom user-defined methods and fields
	[string]: any,
}

--[=[
	@class Controller

	A client-side controller. Created via `Flite.createController()`.
	Controllers handle UI, input, and client-side logic.

	```lua
	local MyController = Flite.createController("MyController", function(self: Flite.Controller)
		local PlotService = self:useService("PlotService")
		self:onInit(function()
			print("Controller initialized")
		end)
	end)
	```
]=]
export type Controller = {
	--[=[
		The name of this controller.
	]=]
	Name: string,
	--[=[
		Reference to the player's PlayerGui. May be nil initially; use `getPlayerGui()` for safe access.
	]=]
	playerGui: PlayerGui?,
	--[=[
		Safely resolve the player's PlayerGui, optionally waiting with a timeout.
	]=]
	getPlayerGui: (self: Controller, timeout: number?) -> PlayerGui?,
	--[=[
		Declare a dependency on another controller. Returns a proxy.

		```lua
		local UIController = self:useController("UIController")
		```
	]=]
	useController: (self: Controller, controllerName: string) -> any,
	--[=[
		Declare a dependency on a server service. Returns a client-side proxy.
		Calling methods on the proxy invokes the server remotely.

		```lua
		local PlotService = self:useService("PlotService")
		```
	]=]
	useService: (self: Controller, serviceName: string) -> any,
	--[=[
		Observe reactive state from a service. Pass a service name or proxy, a field name, and an optional change callback.

		```lua
		self:useServiceState("PlotService", "playerPlots", function(newVal, oldVal)
			print("Plots changed!")
		end)
		```
	]=]
	useServiceState: (self: Controller, target: string | any, field: string, callback: ((newValue: any, oldValue: any) -> ())?) -> any,
	--[=[
		Declare a dependency on a shared domain. Returns a proxy.

		```lua
		local CombatDomain = self:useDomain("CombatDomain")
		```
	]=]
	useDomain: (self: Controller, domainName: string) -> any,
	--[=[
		Register an init callback. Runs once when the controller is initialized.
	]=]
	onInit: (self: Controller, callback: () -> ()) -> (),
	--[=[
		Register a start callback. Runs once when the controller starts.
	]=]
	onStart: (self: Controller, callback: () -> ()) -> (),
	--[=[
		Register a stop callback. Runs when the controller is stopped.
	]=]
	onStop: (self: Controller, callback: () -> ()) -> (),
	--[=[
		Register a callback that runs every frame (RunService.Heartbeat).
	]=]
	onHeartbeat: (self: Controller, callback: (deltaTime: number) -> ()) -> (),
	onHeartbeatFixed: (self: Controller, fixedDeltaTime: number, callback: (deltaTime: number) -> ()) -> (),
	--[=[
		Register a callback that runs every RenderStepped frame. Use for UI/camera updates.
	]=]
	onRenderStepped: (self: Controller, callback: (deltaTime: number) -> ()) -> (),
	onRenderSteppedFixed: (self: Controller, fixedDeltaTime: number, callback: (deltaTime: number) -> ()) -> (),
	--[=[
		Bind a keyboard key. Automatically cleaned up when the controller is destroyed.

		```lua
		self:useKey(Enum.KeyCode.E, function() print("E pressed") end)
		```
	]=]
	useKey: (self: Controller, key: Enum.KeyCode, onPressed: (() -> ())?, onReleased: (() -> ())?) -> (),
	--[=[
		Bind a gamepad button. Automatically cleaned up when the controller is destroyed.

		```lua
		self:useButton(Enum.KeyCode.ButtonA, function() print("A pressed") end)
		```
	]=]
	useButton: (self: Controller, button: Enum.KeyCode, onPressed: (() -> ())?, onReleased: (() -> ())?) -> (),
	--[=[
		Observe instances with a specific CollectionService tag. Callback fires for both add and remove.
	]=]
	observeTag: (self: Controller, tag: string, callback: (instance: Instance, isAdded: boolean) -> ()) -> (),
	--[=[
		Observe tagged instances with separate add/remove callbacks.

		```lua
		self:useTagged("Enemy", function(inst) print("added") end, function(inst) print("removed") end)
		```
	]=]
	useTagged: (self: Controller, tag: string, onAdded: (instance: Instance) -> (), onRemoved: ((instance: Instance) -> ())?) -> (),
	--[=[
		Observe a specific player's character. onAdded fires on spawn, onRemoving fires before removal.
	]=]
	useCharacter: (self: Controller, player: Player, onAdded: (character: Model, player: Player) -> (), onRemoving: ((character: Model, player: Player) -> ())?) -> (),
	--[=[
		Observe the LocalPlayer's character. onAdded fires on spawn, onRemoving fires before removal.
	]=]
	useLocalCharacter: (self: Controller, onAdded: (character: Model, player: Player) -> (), onRemoving: ((character: Model, player: Player) -> ())?) -> (),
	--[=[
		Observe player join/leave events. Callback fires immediately and on each change.
	]=]
	usePlayers: (self: Controller, callback: () -> ()) -> (),
	--[=[
		Apply a WeaveKit theme preset.
	]=]
	useTheme: (self: Controller, themeOptions: { [string]: any }) -> (),
	--[=[
		Wait for a BindableEvent in ReplicatedStorage before proceeding.
	]=]
	useWaitFor: (self: Controller, eventName: string, timeout: number?) -> (),
	--[=[
		Schedule a function to run after a delay.
	]=]
	useTimeout: (self: Controller, fn: () -> (), delayMs: number) -> thread,
	--[=[
		Schedule a function to run repeatedly at an interval.
	]=]
	useInterval: (self: Controller, fn: () -> (), intervalMs: number) -> thread,
	--[=[
		Create and manage a Tween.
	]=]
	useTween: (self: Controller, target: any, info: TweenInfo, goals: {[string]: any}, callback: (() -> ())?) -> { Cancel: () -> (), OnMarker: (number, () -> ()) -> any },
	--[=[
		Debounce a function call.
	]=]
	useDebounce: <T...>(self: Controller, fn: (T...) -> (), delayMs: number) -> (T...) -> (),
	--[=[
		Throttle a function call.
	]=]
	useThrottle: <T...>(self: Controller, fn: (T...) -> (), intervalMs: number) -> (T...) -> (),
	--[=[
		Create a mutable ref object.
	]=]
	useRef: <T>(self: Controller, initialValue: T?) -> { current: T? },
	--[=[
		Memoize a computation based on dependencies.
	]=]
	useMemo: <T>(self: Controller, fn: () -> T, dependencies: {any}) -> () -> T,
	--[=[
		Run side effects when dependencies change.
	]=]
	useEffect: (self: Controller, fn: () -> (() -> ())?, dependencies: {any}) -> () -> (),
	--[=[
		Batch multiple updates together.
	]=]
	useBatch: (self: Controller, waitMs: number) -> ((() -> ()) -> ()),
	--[=[
		Create a rollback state for temporary changes.
	]=]
	useRollback: (self: Controller, state: any, restoreValue: any) -> (() -> ()),
	--[=[
		Create a spring animation.
	]=]
	useSpring: (self: Controller, initialValue: number, stiffness: number?, damping: number?) -> { set: (number) -> (), get: () -> number, immediate: (number) -> () },
	--[=[
		Create a cached resolver with TTL.
	]=]
	useCache: (self: Controller, ttlMs: number, resolver: (...any) -> any) -> ((...any) -> any),
	--[=[
		Run a function only once per key.
	]=]
	useOnce: (self: Controller, key: string, fn: () -> ()) -> (() -> ()),
	--[=[
		Get the previous value of a changing variable.
	]=]
	usePrevious: (self: Controller, value: any) -> any,
	--[=[
		Create a raycast function.
	]=]
	useRaycast: (self: Controller, params: RaycastParams?, trackPlayers: {Player}?) -> ((origin: Vector3, direction: Vector3, maxDistance: number?) -> RaycastResult?),
	--[=[
		Create a blockcast function.
	]=]
	useBlockcast: (self: Controller, params: RaycastParams?, trackPlayers: {Player}?) -> ((size: Vector3, origin: Vector3, direction: Vector3, maxDistance: number?) -> RaycastResult?),
	--[=[
		Create a shapecast function.
	]=]
	useShapecast: (self: Controller, shape: any, params: RaycastParams?, trackPlayers: {Player}?) -> ((cframe: CFrame, direction: Vector3, maxDistance: number?) -> RaycastResult?),
	--[=[
		Create a spherecast function.
	]=]
	useSpherecast: (self: Controller, radius: number, params: RaycastParams?, trackPlayers: {Player}?) -> ((origin: Vector3, direction: Vector3, maxDistance: number?) -> RaycastResult?),
	--[=[
		Create a boxcast function.
	]=]
	useBoxcast: (self: Controller, size: Vector3, params: RaycastParams?, trackPlayers: {Player}?) -> ((cframe: CFrame, direction: Vector3, maxDistance: number?) -> RaycastResult?),
	--[=[
		Create a touch detection function that fires on both enter and exit.
	]=]
	useTouched: (self: Controller, target: Instance | () -> CFrame, radius: number?, params: OverlapParams?, trackPlayers: {Player}?) -> { Connect: ((callback: (otherPart: Instance, isEntering: boolean) -> ()) -> { Disconnect: () -> () }), Once: ((callback: (otherPart: Instance, isEntering: boolean) -> ()) -> { Disconnect: () -> () }), DisconnectAll: () -> () },
	--[=[
		Get all instances with a specific tag.
	]=]
	getTagged: (self: Controller, tag: string) -> {Instance},
	--[=[
		Check if an instance has a specific tag.
	]=]
	hasTag: (self: Controller, instance: Instance, tag: string) -> boolean,
	--[=[
		Create a sound object.
	]=]
	useSound: (self: Controller, soundId: string, props: {[string]: any}?) -> { play: () -> (), stop: () -> (), instance: Sound },
	-- Allow custom user-defined methods and fields
	[string]: any,
}

--[=[
	@class Domain

	A shared domain. Created via `Flite.createDomain()`.
	Domains contain pure logic that runs identically on both server and client.
	They can only depend on other domains, not on services or controllers.

	```lua
	local CombatDomain = Flite.createDomain("CombatDomain", function(self: Flite.Domain)
		self:expose("takeDamage", function(self, target, amount)
			-- pure logic
		end)
	end)
	```
]=]
export type Domain = {
	--[=[
		The name of this domain.
	]=]
	Name: string,
	--[=[
		Declare a dependency on another domain. Returns a proxy.

		```lua
		local PhysicsDomain = self:useDependency("PhysicsDomain")
		```
	]=]
	useDependency: (self: Domain, domainName: string) -> any,
	--[=[
		Expose a method on the domain.
		On the server, exposed methods are callable directly.
		On the client, exposed methods execute optimistically and dispatch silently to the server.

		```lua
		self:expose("takeDamage", function(self, target, amount)
			return target.health - amount
		end)
		```
	]=]
	expose: (self: Domain, method: string, callback: any, options: any?) -> (),
	--[=[
		Schedule a function to run after a delay.
	]=]
	useTimeout: (self: Domain, fn: () -> (), delayMs: number) -> thread,
	--[=[
		Schedule a function to run repeatedly at an interval.
	]=]
	useInterval: (self: Domain, fn: () -> (), intervalMs: number) -> thread,
	--[=[
		Create and manage a Tween.
	]=]
	useTween: (self: Domain, target: any, info: TweenInfo, goals: {[string]: any}, callback: (() -> ())?) -> { Cancel: () -> (), OnMarker: (number, () -> ()) -> any },
	--[=[
		Debounce a function call.
	]=]
	useDebounce: <T...>(self: Domain, fn: (T...) -> (), delayMs: number) -> (T...) -> (),
	--[=[
		Throttle a function call.
	]=]
	useThrottle: <T...>(self: Domain, fn: (T...) -> (), intervalMs: number) -> (T...) -> (),
	--[=[
		Create a mutable ref object.
	]=]
	useRef: <T>(self: Domain, initialValue: T?) -> { current: T? },
	--[=[
		Memoize a computation based on dependencies.
	]=]
	useMemo: <T>(self: Domain, fn: () -> T, dependencies: {any}) -> () -> T,
	--[=[
		Run side effects when dependencies change.
	]=]
	useEffect: (self: Domain, fn: () -> (() -> ())?, dependencies: {any}) -> () -> (),
	--[=[
		Batch multiple updates together.
	]=]
	useBatch: (self: Domain, waitMs: number) -> ((() -> ()) -> ()),
	--[=[
		Create a rollback state for temporary changes.
	]=]
	useRollback: (self: Domain, state: any, restoreValue: any) -> (() -> ()),
	--[=[
		Create a spring animation.
	]=]
	useSpring: (self: Domain, initialValue: number, stiffness: number?, damping: number?) -> { set: (number) -> (), get: () -> number, immediate: (number) -> () },
	--[=[
		Create a cached resolver with TTL.
	]=]
	useCache: (self: Domain, ttlMs: number, resolver: (...any) -> any) -> ((...any) -> any),
	--[=[
		Run a function only once per key.
	]=]
	useOnce: (self: Domain, key: string, fn: () -> ()) -> (() -> ()),
	--[=[
		Get the previous value of a changing variable.
	]=]
	usePrevious: (self: Domain, value: any) -> any,
	--[=[
		Create a raycast function.
	]=]
	useRaycast: (self: Domain, params: RaycastParams?, trackPlayers: {Player}?) -> ((origin: Vector3, direction: Vector3, maxDistance: number?) -> RaycastResult?),
	--[=[
		Create a blockcast function.
	]=]
	useBlockcast: (self: Domain, params: RaycastParams?, trackPlayers: {Player}?) -> ((size: Vector3, origin: Vector3, direction: Vector3, maxDistance: number?) -> RaycastResult?),
	--[=[
		Create a shapecast function.
	]=]
	useShapecast: (self: Domain, shape: any, params: RaycastParams?, trackPlayers: {Player}?) -> ((cframe: CFrame, direction: Vector3, maxDistance: number?) -> RaycastResult?),
	--[=[
		Create a spherecast function.
	]=]
	useSpherecast: (self: Domain, radius: number, params: RaycastParams?, trackPlayers: {Player}?) -> ((origin: Vector3, direction: Vector3, maxDistance: number?) -> RaycastResult?),
	--[=[
		Create a boxcast function.
	]=]
	useBoxcast: (self: Domain, size: Vector3, params: RaycastParams?, trackPlayers: {Player}?) -> ((cframe: CFrame, direction: Vector3, maxDistance: number?) -> RaycastResult?),
	--[=[
		Create a touch detection function that fires on both enter and exit.
	]=]
	useTouched: (self: Domain, target: Instance | () -> CFrame, radius: number?, params: OverlapParams?, trackPlayers: {Player}?) -> { Connect: ((callback: (otherPart: Instance, isEntering: boolean) -> ()) -> { Disconnect: () -> () }), Once: ((callback: (otherPart: Instance, isEntering: boolean) -> ()) -> { Disconnect: () -> () }), DisconnectAll: () -> () },
	--[=[
		Observe instances with a specific tag.
	]=]
	observeTag: (self: Domain, tag: string, callback: (instance: Instance, isTagged: boolean) -> ()) -> (),
	--[=[
		Observe tagged instances with separate add/remove callbacks.
	]=]
	useTagged: (self: Domain, tag: string, onAdded: (instance: Instance) -> (), onRemoved: ((instance: Instance) -> ())?) -> (),
	--[=[
		Get all instances with a specific tag.
	]=]
	getTagged: (self: Domain, tag: string) -> {Instance},
	--[=[
		Check if an instance has a specific tag.
	]=]
	hasTag: (self: Domain, instance: Instance, tag: string) -> boolean,
	-- Allow custom user-defined methods and fields
	[string]: any,
}

--[=[
	Composable hooks-based game framework built on Weave.

	```lua
	-- Server
	local Flite = require(ReplicatedStorage.Libraries.Flite)
	Flite.createService("MyService", function(self: Flite.Service)
		self:onInit(function() print("ready") end)
	end)
	Flite.start()
	```
]=]

local Framework = {}
local services = {}
local controllers = {}
local domains = {}

local FrameworkServer = nil
local FrameworkClient = nil
if RunService:IsServer() then
	FrameworkServer = require(script.Server.FrameworkServer)
else
	FrameworkClient = require(script.Client.FrameworkClient)
end
local runtimeCleanup: (() -> ())? = nil
local started = false
type StartOptions = {
	deferLifecycle: boolean?,
	parallelInit: boolean?,
	manifestOnly: boolean?,
}
local startupOptions: StartOptions = {}

--[=[
	Define a contract for input validation.
	Returns a cloned table with a `__frameworkContract` marker.
]=]
function Framework.contract(definition: any)
	if type(definition) ~= "table" then
		error("[Framework] contract(definition) expects a table.")
	end

	local contract = table.clone(definition)
	contract.__frameworkContract = true
	return contract
end

Framework.CancelToken = CancelToken
Framework.Errors = FrameworkError.Codes
Framework.perm = PermissionPolicy

--[=[
	Create a framework error object.
	@param code -- Error code string.
	@param message -- Human-readable error message.
	@param details -- Optional additional context.
]=]
function Framework.error(code: string, message: string, details: any?)
	return FrameworkError.new(code, message, details)
end

local function mergeStartupOptions(options: StartOptions?)
	if not options then
		return
	end

	if options.deferLifecycle ~= nil then
		startupOptions.deferLifecycle = options.deferLifecycle
	end
	if options.parallelInit ~= nil then
		startupOptions.parallelInit = options.parallelInit
	end
	if options.manifestOnly ~= nil then
		startupOptions.manifestOnly = options.manifestOnly
	end

	if RunService:IsServer() then
		FrameworkBootstrap.setManifestMode(FrameworkComm, startupOptions.manifestOnly == true)
	end
end

--[=[
	Configure startup options before calling `Flite.start()`.
	@param options -- Table with optional keys: `deferLifecycle`, `parallelInit`, `manifestOnly`.
]=]
function Framework.configure(options: StartOptions)
	mergeStartupOptions(options)
end

--[=[
	Create a server-side service.

	```lua
	Flite.createService("PlotService", function(self: Flite.Service)
		self:useMapState("playerPlots")
		self:onPlayerAdded(function(player) end)
	end)
	```

	@param name -- Unique name for the service.
	@param setupFn -- Callback receiving the service context.
	@return Service
]=]
function Framework.createService<T...>(name: string, setupFn: (service: Service) -> ()): Service
	if not RunService:IsServer() then
		error("[Framework] createService can only be called on the server.")
	end
	if services[name] then
		error(`[Framework] Service "{name}" already exists.`)
	end

	if not FrameworkServer then
		FrameworkServer = require(script.Server.FrameworkServer)
	end
	return FrameworkServer.createService(
		name,
		setupFn,
		services,
		domains,
		FrameworkComm.StateEvent,
		FrameworkComm.SignalEvent,
		FrameworkComm.UnreliableSignalEvent,
		startupOptions
	)
end

--[=[
	Create a client-side controller.

	```lua
	Flite.createController("MyController", function(self: Flite.Controller)
		self:onInit(function() print("ready") end)
	end)
	```

	@param name -- Unique name for the controller.
	@param setupFn -- Callback receiving the controller context.
	@return Controller
]=]
function Framework.createController(name: string, setupFn: (controller: Controller) -> ()): Controller
	if RunService:IsServer() then
		error("[Framework] createController can only be called on the client.")
	end
	if controllers[name] then
		error(`[Framework] Controller "{name}" already exists.`)
	end

	if not FrameworkClient then
		FrameworkClient = require(script.Client.FrameworkClient)
	end
	return FrameworkClient.createController(name, setupFn, controllers, services, domains, FrameworkComm)
end

--[=[
	Create a shared domain. Domains run identically on server and client.

	```lua
	Flite.createDomain("CombatDomain", function(self: Flite.Domain)
		self:expose("takeDamage", function(self, target, amount) end)
	end)
	```

	@param name -- Unique name for the domain.
	@param setupFn -- Callback receiving the domain context.
	@return Domain
]=]
function Framework.createDomain(name: string, setupFn: (domain: Domain) -> ()): Domain
	if domains[name] then
		error(`[Framework] Domain "{name}" already exists.`)
	end

	if RunService:IsServer() then
		if not FrameworkServer then
			FrameworkServer = require(script.Server.FrameworkServer)
		end
		return FrameworkServer.createDomain(name, setupFn, domains, services)
	else
		local DomainBuilder = require(script.Shared.DomainBuilder)
		local domain = DomainBuilder.build(name, function(domainName)
			assert(domains[domainName], `[Framework] Domain "{domainName}" not found`)
			return domains[domainName]
		end, setupFn)
		domains[name] = domain
		return domain
	end
end

--[=[
	Load all ModuleScripts in a folder as framework modules.
	Modules are sorted alphabetically and required in order.

	@param folder -- The folder containing ModuleScripts.
	@return number -- The number of modules loaded.
]=]
function Framework.loadModules(folder: Instance?): number
	if not folder then
		return 0
	end

	local modules = {}
	for _, descendant in folder:GetDescendants() do
		if descendant:IsA("ModuleScript") then
			table.insert(modules, descendant)
		end
	end

	table.sort(modules, function(a, b)
		return a:GetFullName() < b:GetFullName()
	end)

	for _, module in modules do
		require(module)
	end

	return #modules
end

--[=[
	Get a client-side proxy to a server service (Client only).

	@param name -- Name of the service to retrieve.
	@return any -- Service proxy with reactive state fields and callable methods.
]=]
function Framework.getService(name: string): any
	if RunService:IsServer() then
		error("[Framework] getService is for Client use only.")
	end

	if not FrameworkClient then
		FrameworkClient = require(script.Client.FrameworkClient)
	end
	return FrameworkClient.getService(name, services, FrameworkComm)
end

--[=[
	Get a client-side proxy to a shared domain (Client only).

	@param name -- Name of the domain to retrieve.
	@return any -- Domain proxy with exposed methods.
]=]
function Framework.getDomain(name: string): any
	if RunService:IsServer() then
		error("[Framework] getDomain is for Client use only.")
	end

	if not FrameworkClient then
		FrameworkClient = require(script.Client.FrameworkClient)
	end
	return FrameworkClient.getDomain(name, domains, FrameworkComm, services)
end

--[=[
	Start the framework. Initializes and starts all registered services/controllers.

	@param options -- Optional startup options (`deferLifecycle`, `parallelInit`, `manifestOnly`).
]=]
function Framework.start(options: StartOptions?)
	mergeStartupOptions(options)
	local startOptions = startupOptions
	if started then
		return
	end

	if RunService:IsServer() then
		if not FrameworkServer then
			FrameworkServer = require(script.Server.FrameworkServer)
		end
		local cleanupNetwork = FrameworkBootstrap.attachServerNetwork(services, domains, FrameworkComm)
		local cleanupServices = FrameworkServer.start(services, domains, startOptions)
		runtimeCleanup = function()
			cleanupServices()
			cleanupNetwork()
		end
	else
		if not FrameworkClient then
			FrameworkClient = require(script.Client.FrameworkClient)
		end
		local cleanupListeners = FrameworkBootstrap.attachClientListeners(services, FrameworkComm)
		local cleanupControllers = FrameworkClient.start(controllers, startOptions)
		runtimeCleanup = function()
			cleanupControllers()
			cleanupListeners()
		end
	end

	started = true
	rawset(Framework, "_cleanup", runtimeCleanup)
end

--[=[
	Stop the framework. Cleans up all services/controllers and disconnects all listeners.
]=]
function Framework.stop()
	if not started then
		return
	end

	started = false
	if runtimeCleanup then
		runtimeCleanup()
		runtimeCleanup = nil
	end
	startupOptions = {}
	rawset(Framework, "_cleanup", nil)
end

return Framework
