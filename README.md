# Flite

A composable hooks-based game framework for Roblox, built on
[Weave](https://github.com/royhanantariksaaa/weave-rbx) and
[Echo](https://github.com/royhanantariksaaa/echo-rbx).

Flite helps you structure Roblox games using **Services** (server logic),
**Controllers** (client logic), and **Domains** (shared logic) — with reactive
state replication, typed network contracts, permission policies, DataStore
persistence, and structured error handling.

Inspired by Express-style architecture and Knit, but with fine-grained
reactivity powered by Weave's signal engine.

---

## Table of Contents

- [Installation](#installation)
- [Quick Start](#quick-start)
- [Architecture Overview](#architecture-overview)
- [Services](#services)
  - [Service Hooks Reference](#service-hooks-reference)
  - [Exposing Methods](#exposing-methods)
  - [Signals](#signals)
- [Controllers](#controllers)
  - [Controller Hooks Reference](#controller-hooks-reference)
- [Domains](#domains)
- [State Types & Replication](#state-types--replication)
- [Permissions](#permissions)
- [Persistence (DataStore)](#persistence-datastore)
- [Error Handling & Cancellation](#error-handling--cancellation)
- [Universal Hooks](#universal-hooks)
- [Integration with Weave & Echo](#integration-with-weave--echo)

---

## Installation

### Runtime dependencies

Flite uses **absolute requires** to modules in `ReplicatedStorage.Libraries`.
At runtime, the following must be present:

| Dependency | Path | Purpose |
|------------|------|---------|
| [Weave](https://github.com/royhanantariksaaa/weave-rbx) | `.Weave` | Reactivity + UI (also brings Echo, Symbol, Tween) |
| [Echo](https://github.com/royhanantariksaaa/echo-rbx) | `.Echo` | Signal engine (for state replication) |
| [WeaveKit](https://github.com/royhanantariksaaa/weavekit-rbx) | `.WeaveKit` | Optional — only for client `useTheme` hook |
| `Promise` | `.Promise` | Promise library (for remote method calls) |
| `Tween` | `.Tween` | SoA tween scheduler |

### As a git submodule

```sh
git submodule add https://github.com/royhanantariksaaa/echo-rbx.git   src/Shared/Libraries/Echo
git submodule add https://github.com/royhanantariksaaa/weave-rbx.git  src/Shared/Libraries/Weave
git submodule add https://github.com/royhanantariksaaa/weavekit-rbx.git src/Shared/Libraries/WeaveKit
git submodule add https://github.com/royhanantariksaaa/flite-rbx.git  src/Shared/Libraries/Flite
```

Then provide `Promise` and `Tween` at `ReplicatedStorage.Libraries/<Name>`.

---

## Quick Start

A complete server + client example: a coin system with replication.

**Server** — define a service with replicated state:

```lua
-- ServerScriptService/Services/CoinService.luau
local Flite = require(ReplicatedStorage.Libraries.Flite)

return Flite.createService("CoinService", function(self)
    -- Per-player replicated state (auto-syncs to each client)
    local coins = self:useMapState("coins", 0)

    self:onPlayerAdded(function(player)
        coins:set(player, 100)  -- starting coins
    end)

    -- Expose a remoted method the client can call
    self:expose("addCoins", {
        args = { "number" },         -- type-validate the argument
        allow = Flite.perm.allowAll(),
    }, function(service, player, amount)
        local current = coins:get(player)
        coins:set(player, current + amount)
        return coins:get(player)     -- return value sent to client
    end)
end)
```

**Client** — define a controller that reads state and calls methods:

```lua
-- StarterPlayerScripts/Controllers/HUDController.luau
local Flite = require(ReplicatedStorage.Libraries.Flite)

return Flite.createController("HUDController", function(self)
    local coinService = self:useService("CoinService")

    -- Reactive state that auto-updates from server replication
    local coins = self:useServiceState("CoinService", "coins")

    self:onStart(function()
        print("Starting coins:", coins:Get())

        -- Subscribe to changes
        self:Observe(coins, function(new)
            print("Coins:", new)
            -- Update your UI here
        end)

        -- Call the exposed server method (returns a Promise)
        coinService.addCoins(50):andThen(function(newTotal)
            print("Total coins:", newTotal)
        end)
    end)
end)
```

**Bootstrapping** — start the framework:

```lua
-- ServerScriptService/init.server.luau
local Flite = require(ReplicatedStorage.Libraries.Flite)

-- Auto-require all service modules
Flite.loadModules(script.Services)
Flite.start()
```

```lua
-- StarterPlayerScripts/init.client.luau
local Flite = require(ReplicatedStorage.Libraries.Flite)

Flite.loadModules(script.Controllers)
Flite.start()
```

---

## Architecture Overview

```
┌─────────────────────────────────────────────┐
│                 FLITE                        │
│                                              │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  │
│  │ Services │  │ Domains  │  │Controllers│  │
│  │ (server) │  │ (shared) │  │ (client) │  │
│  └────┬─────┘  └────┬─────┘  └────┬─────┘  │
│       │              │              │        │
│       └──────────────┴──────────────┘        │
│                     │                        │
│              ┌──────┴──────┐                 │
│              │   WEAVE     │                 │
│              │ (reactivity)│                 │
│              └──────┬──────┘                 │
│                     │                        │
│              ┌──────┴──────┐                 │
│              │    ECHO     │                 │
│              │  (signals)  │                 │
│              └─────────────┘                 │
└─────────────────────────────────────────────┘
```

- **Services** run on the server. They hold authoritative state, expose remoted
  methods, handle persistence, and manage player lifecycle.
- **Controllers** run on the client. Each gets a Weave scope for reactive UI,
  plus Flite hooks for input, rendering, and service access.
- **Domains** are shared logic modules that run on both sides. They provide
  optimistic prediction on the client with automatic rollback on server rejection.

Communication flows through a single set of remotes in
`ReplicatedStorage.FrameworkComm`:

| Remote | Type | Purpose |
|--------|------|---------|
| `StateEvent` | RemoteEvent | State replication (server → client) + initial value requests (client → server) |
| `SignalEvent` | RemoteEvent | Signal firing (both directions) |
| `MethodEvent` | RemoteFunction | Remote method invocation (client → server) |
| `UnreliableSignalEvent` | UnreliableRemoteEvent | High-frequency signals (no ordering guarantee) |

---

## Services

Services are the server-side authority. Define them with `Flite.createService`:

```lua
Flite.createService("MatchService", function(self)
    local phase = self:useValueState("phase", "waiting")  -- global replicated state
    local scores = self:useMapState("scores", 0)          -- per-player state

    self:onInit(function()
        -- Runs first, before any onStart. Good for setup.
        print("MatchService initializing")
    end)

    self:onStart(function()
        -- Runs after all services have initialized.
        phase:set("in-progress")
    end)

    self:onPlayerAdded(function(player)
        scores:set(player, 0)
    end)

    self:onPlayerRemoving(function(player)
        print("Final score:", scores:get(player))
    end)

    self:onHeartbeat(function(dt)
        -- Runs every frame
    end)
end)
```

### Service Hooks Reference

#### State & Signals (setup phase)

| Hook | Signature | Description |
|------|-----------|-------------|
| `useMapState(name, default)` | `(string, V) -> MapState<V>` | Per-player keyed state. Replicates each player's value to that player. |
| `useValueState(name, default)` | `(string, V) -> ValueState<V>` | Global scalar state. Replicates to all clients. |
| `useChannelState(name, default)` | `(string, V) -> ChannelState<V>` | Subscription-based state. Only replicates to subscribed players. |
| `useComputedState(name, deps, fn, opts?)` | `(string, {state}, fn, {replicate?}) -> ComputedState` | Derived state from other states. `replicate = true` sends to clients. |
| `useGlobalValue(name, default?)` | `(string, V?) -> GlobalValueState<V>` | Cross-server sync via MemoryStoreService + MessagingService. |
| `useSignal(name, schema?)` | `(string, schema?) -> Signal` | Networked signal (reliable). |
| `useUnreliableSignal(name, schema?)` | `(string, schema?) -> Signal` | Networked signal (unreliable, for high-frequency data). |
| `useGlobalSignal(name)` | `(string) -> {fire, connect}` | MessagingService-backed cross-server signal. |

#### Lifecycle

| Hook | When | Signature |
|------|------|-----------|
| `onInit(fn)` | Boot phase 1 (before onStart) | `(() -> ()) -> ()` |
| `onStart(fn)` | Boot phase 2 (after all inits) | `(() -> ()) -> ()` |
| `onPlayerAdded(fn)` | Player joins (and existing players) | `((Player) -> ()) -> ()` |
| `onPlayerRemoving(fn)` | Player leaves | `((Player) -> ()) -> ()` |
| `onPlayerSpawned(fn)` | Character spawns | `((Player, Model) -> ()) -> ()` |
| `onPlayerDespawned(fn)` | Character despawns | `((Player, Model) -> ()) -> ()` |
| `onHeartbeat(fn)` | Every frame | `((dt: number) -> ()) -> ()` |
| `onHeartbeatFixed(fixedDt, fn)` | Fixed-timestep heartbeat | `(number, (dt) -> ()) -> ()` |
| `beforeServerShutdown(fn)` | `game:BindToClose` | `((reason: string?) -> ()) -> ()` |
| `onStop(fn)` | Framework teardown | `(() -> ()) -> ()` |

#### Other

| Hook | Description |
|------|-------------|
| `useMiddleware(fn)` | Global middleware: `(Player, methodName, ...args) -> boolean` |
| `expose(method, config?, fn?)` | Expose a remoted method (see below) |
| `useDependency(serviceName)` | Access another service or domain |
| `useRateLimit(key, limit, windowMs)` | Per-player rate limiter factory |
| `useTransaction(state)` | Guarded transactional update helper |
| `usePersistent(store, fields?)` | Enable DataStore persistence (see below) |

### Exposing Methods

Exposed methods are callable from the client via `ServiceProxy`. Each method
receives `(service, player, ...args, requestContext)`:

```lua
self:expose("transferCoins", {
    args = { "Player", "number" },              -- type validation
    returns = { "boolean" },                     -- return validation
    rateLimit = { limit = 5, window = 1000 },    -- 5 calls/sec per player
    onSpam = function(player)
        warn(player.Name .. " is spamming transferCoins")
    end,
    allow = Flite.perm.custom(function(ctx)
        return ctx.player:FindFirstChild("CanTrade") ~= nil, "Trading disabled"
    end),
}, function(service, player, target, amount)
    local coins = service.coins
    if coins:get(player) < amount then
        return nil, Flite.error("ValidationError", "Insufficient coins")
    end
    coins:set(player, coins:get(player) - amount)
    coins:set(target, coins:get(target) + amount)
    return true
end)
```

On the client:

```lua
local inventory = self:useService("InventoryService")

inventory.transferCoins(targetPlayer, 50)
    :andThen(function(success) print("Transfer complete") end)
    :catch(function(err)
        print("Failed:", err.code, err.message)
    end)
```

The `requestContext` (last argument) provides:

```lua
function(service, player, amount, ctx)
    ctx:assertActive()          -- throws if timed out or canceled
    ctx.elapsedMs()             -- time since request started
    ctx:pushProgress({ status = "processing" })  -- stream progress to client
    ctx:error("RateLimited", "Too fast")
end
```

### Signals

Signals are fire-and-listen events that can cross the network:

```lua
-- Server: define and fire
local notify = self:useSignal("Notify")

notify:fire("server-local only")         -- server-side listeners only
notify:fireAllClients("to all clients")   -- clients only
notify:fireAll("everywhere")              -- server + all clients
notify:fireClientAndLocal(player, "hi")   -- one client + server

-- Client: listen
local notifService = self:useService("NotificationService")
notifService.Notify:connect(function(message)
    print("Got notified:", message)
end)

-- Client: fire to server
notifService.Notify:fireServer("client → server")
```

---

## Controllers

Controllers are the client-side logic layer. Each controller receives a
**Weave scope** extended with Flite hooks:

```lua
Flite.createController("UIController", function(self)
    local playerGui = self:getPlayerGui()
    local Weave = require(ReplicatedStorage.Libraries.Weave)

    self:onInit(function()
        -- Setup phase
    end)

    self:onStart(function()
        -- Mount reactive UI
        Weave.mount(playerGui, "MainUI", function(scope)
            local menuService = self:useService("MenuService")
            local visible = self:useServiceState("MenuService", "isOpen")

            return scope:Frame {
                Visible = visible,
                -- ... full Weave UI here
            }
        end)
    end)

    self:onRenderStepped(function(dt)
        -- Per-frame logic (camera, effects, etc.)
    end)
end)
```

### Controller Hooks Reference

| Hook | Signature | Description |
|------|-----------|-------------|
| `useController(name)` | `(string) -> Controller` | Access another controller. |
| `useService(name)` | `(string) -> ServiceProxy` | Access a server service's proxy. |
| `useServiceState(svc, field, cb?)` | `(string, string, fn?) -> State` | Bind to a replicated server state. |
| `useDomain(name)` | `(string) -> DomainProxy` | Access a shared domain. |
| `useSound(id, props?)` | `(number, table?) -> {play, stop}` | Play a sound parented to camera. |
| `getPlayerGui(timeout?)` | `(number?) -> PlayerGui?` | Resolve PlayerGui safely. |
| `useKey(keyCode, onDown?, onUp?)` | `(Enum.KeyCode, fn?, fn?)` | Lazy keyboard binding. |
| `useButton(keyCode, onDown?, onUp?)` | `(Enum.KeyCode, fn?, fn?)` | Gamepad button binding. |
| `useLocalCharacter(onAdded, onRemove?)` | `(fn, fn?)` | Observe LocalPlayer's character. |
| `usePlayers(callback)` | `(() -> ())` | Fires immediately + on join/leave. |
| `useTheme(preset)` | `(table)` | Set WeaveKit theme. |
| **Lifecycle** | | |
| `onInit(fn)` | `(() -> ())` | Setup phase. |
| `onStart(fn)` | `(() -> ())` | After all controllers init'd. |
| `onStop(fn)` | `(() -> ())` | Teardown. |
| `onHeartbeat(fn)` / `onHeartbeatFixed(dt, fn)` | `((dt) -> ())` | Per-frame. |
| `onRenderStepped(fn)` / `onRenderSteppedFixed(dt, fn)` | `((dt) -> ())` | Per-render. |

Controllers also inherit **all Weave scope methods** (`Value`, `Computed`,
`Spring`, `Show`, `ForValues`, `Watch`, `Drag`, etc.) — see the
[Weave README](https://github.com/royhanantariksaaa/weave-rbx) for the full list.

---

## Domains

Domains are shared logic modules that run on **both** server and client. They
enable optimistic local prediction with automatic rollback.

```lua
-- Shared/Domains/MovementDomain.luau
return Flite.createDomain("MovementDomain", function(self)
    -- Depend on other domains (not services)
    local physics = self:useDependency("PhysicsDomain")

    -- Expose a method callable from both sides
    self:expose("move", {
        args = { "Vector3" },
    }, function(system, player, direction)
        -- On server: `system` has real service access
        -- On client: `system` has mock state for prediction
        local character = player.Character
        if character then
            local hrp = character:FindFirstChild("HumanoidRootPart")
            if hrp then
                hrp.CFrame = hrp.CFrame + direction
            end
        end
    end)

    -- Domain-local events
    self:expose("onLanded", function(system, player)
        system.emit("landed", { player = player })
    end)
end)
```

**Client prediction:** When called from a client controller, the domain method
runs **immediately** against mock state. The same call is then sent to the
server. If the server rejects (returns an error), the client **rolls back** the
predicted state changes automatically.

```lua
-- Client controller
local movement = self:useDomain("MovementDomain")
movement.move(Vector3.new(0, 0, -5))  -- predicted locally, confirmed by server
```

Domain events use a local event bus:

```lua
-- Any domain method body
system.on("landed", function(payload)
    print(payload.player.Name .. " landed!")
end)
system.emit("landed", { player = somePlayer })
```

---

## State Types & Replication

Flite provides five server-side state types that automatically replicate to
clients:

### MapState — per-player values

Each player gets their own value. Replicates to that player only.

```lua
local health = self:useMapState("health", 100)

health:set(player, 75)           -- set for one player
health:setFilter(function(p)     -- set for all alive players
    return p.Character ~= nil
end, 100)
health:get(player)               -- read one player's value
health:clear(player)             -- reset to default
for key, value in health:getEach() do  -- iterate all
    print(key, value)
end
```

### ValueState — global value

Single value replicated to all clients.

```lua
local phase = self:useValueState("phase", "lobby")
phase:set("starting")
phase:get()  -- "starting"
```

### ChannelState — subscription-based

Only replicates to subscribed players. Good for region/instance-specific data.

```lua
local zoneWeather = self:useChannelState("zoneWeather", "clear")

-- Player enters a zone
zoneWeather:subscribe(player)
zoneWeather:set("rain")  -- only subscribed players receive this
zoneWeather:unsubscribe(player)
```

### ComputedState — derived

Automatically recalculates when dependencies change. Optionally replicates.

```lua
local baseHealth = self:useMapState("baseHealth", 100)
local buffs = self:useMapState("buffs", 0)

local effectiveHealth = self:useComputedState(
    "effectiveHealth",
    { baseHealth, buffs },
    function(base, buff)
        return base + buff
    end,
    { replicate = true }
)
```

### GlobalValueState — cross-server

Uses MemoryStoreService for persistence and MessagingService for fast
replication across server instances.

```lua
local serverTime = self:useGlobalValue("serverTime", 0)

serverTime:update(function(current)
    return current + 1
end)
```

---

## Permissions

Use `Flite.perm` to gate exposed methods. Policies can be composed:

```lua
local perm = Flite.perm

self:expose("adminCommand", {
    allow = perm.all(
        perm.groupRank(12345, 200),        -- must be rank 200+ in group
        perm.negate(perm.userIds({ 999 })) -- but NOT this user
    ),
}, function(service, player, ...)
    -- ...
end)

-- Built-in policies
perm.allowAll()                    -- always allow
perm.deny("Under maintenance")     -- always deny
perm.team("Red")                   -- on team "Red"
perm.groupRank(groupId, minRank)   -- group rank check
perm.userIds({ 123, 456 })         -- specific user IDs
perm.custom(function(ctx)          -- custom predicate
    return ctx.player:GetRankInGroup(123) > 100, "Insufficient rank"
end)
perm.any(p1, p2, p3)              -- any child allows
perm.all(p1, p2, p3)              -- all children must allow
perm.negate(p1)                   -- invert
```

---

## Persistence (DataStore)

### Basic persistence

Mark a service as persistent and Flite auto-saves/restores MapState fields:

```lua
local Flite = require(ReplicatedStorage.Libraries.Flite)
local DataStoreWrapper = require(ReplicatedStorage.Libraries.Flite.Server.DataStoreWrapper)

Flite.createService("InventoryService", function(self)
    local slots = self:useMapState("slots", {})
    local coins = self:useMapState("coins", 0)

    -- Auto-persist these fields per-player
    local store = DataStoreWrapper.createStore({
        Name = "PlayerInventory",
        Schema = {
            Initial = { coins = 0, slots = {} },
            Migrations = {},
        },
        FlushInterval = 60,  -- auto-flush every 60s
    })

    self:usePersistent(store)  -- persists all MapState fields

    self:onPlayerReady(function(profile, player, data)
        -- Data loaded and states initialized
        print(player.Name .. " loaded with " .. data.coins .. " coins")
    end)

    self:onPlayerSessionEnd(function(profile, player, data, reason)
        print(player.Name .. " leaving. Final data saved.")
    end)
end)
```

### Manual DataStore usage

```lua
local store = DataStoreWrapper.createStore({
    Name = "GlobalState",
    Schema = { Initial = {}, Migrations = {} },
})

local data = DataStoreWrapper.startSession(store, "match_001")
data.winner = "Alice"
DataStoreWrapper.update(store, "match_001", function(d)
    d.completed = true
    return d
end)
DataStoreWrapper.flush(store, "match_001")  -- explicit save
DataStoreWrapper.stopSession(store, "match_001")
```

---

## Error Handling & Cancellation

### Structured errors

```lua
-- Server: return an error as the second return value
self:expose("purchase", function(service, player, itemId)
    local coins = service.coins
    local price = getItemPrice(itemId)
    if coins:get(player) < price then
        return nil, Flite.error(
            "ValidationError",
            "Not enough coins",
            { needed = price, has = coins:get(player) }
        )
    end
    coins:set(player, coins:get(player) - price)
    return itemId
end)
```

Error codes: `ValidationError`, `PermissionDenied`, `RateLimited`,
`RejectedByMiddleware`, `Timeout`, `Canceled`, `ServiceNotFound`,
`MethodNotFound`, `DomainNotFound`, `ServerError`.

### Cancellation tokens

Clients can cancel in-flight method calls:

```lua
local token = Flite.CancelToken.new()

-- Pass as the last argument
inventory.longOperation(token):andThen(...)

-- Cancel later
token:cancel("user navigated away")

-- Or check on the server side
self:expose("longOperation", function(service, player, ctx)
    for i = 1, 1000 do
        ctx:assertActive()  -- throws if canceled or timed out
        task.wait(0.1)
    end
end)
```

---

## Universal Hooks

All services, controllers, and domains share these universal hooks:

### Timing

| Hook | Signature | Description |
|------|-----------|-------------|
| `useTimeout(fn, ms)` | `(fn, number) -> thread` | Delayed callback. |
| `useInterval(fn, ms)` | `(fn, number) -> thread` | Repeating callback. |
| `useDebounce(fn, ms)` | `(fn, number) -> caller` | Debounced caller. |
| `useThrottle(fn, ms)` | `(fn, number) -> caller` | Throttled caller. |
| `useTween(target, info, goals, cb?)` | `(Instance, TweenInfo, table, fn?)` | Tween with auto-cleanup. |

### State & memoization

| Hook | Description |
|------|-------------|
| `useRef(initial?)` | Mutable `{ current }` ref. |
| `useMemo(fn, deps)` | Memoized getter; recomputes when deps change. |
| `useEffect(fn, deps)` | Runs on dep change; supports cleanup return. |
| `useBatch(ms)` | Batched caller (coalesce rapid calls). |
| `useRollback(state, value)` | Restore state to value on cleanup. |
| `useSpring(initial, stiffness?, damping?)` | Heartbeat-driven spring. |
| `usePrevious(value)` | Returns previous value. |

### World queries

| Hook | Description |
|------|-------------|
| `useRaycast(params?, track?)` | `(origin, dir, maxDist?) -> RaycastResult?` |
| `useBlockcast(params?, track?)` | `(size, origin, dir, maxDist?) -> RaycastResult?` |
| `useSpherecast(params?, track?)` | `(origin, dir, maxDist?) -> RaycastResult?` |
| `useBoxcast(params?, track?)` | `(cframe, dir, maxDist?) -> RaycastResult?` |
| `useTouched(target, radius?, params?, track?)` | Overlap detection: `{Connect, Once, DisconnectAll}` |

### CollectionService

| Hook | Description |
|------|-------------|
| `useTagged(tag, onAdded, onRemoved?)` | Track tagged instances. |
| `getTagged(tag)` | List of tagged instances. |
| `hasTag(instance, tag)` | Boolean check. |
| `observeTag(tag, callback)` | `(tag, (Instance, isTagged) -> ())` |

---

## Integration with Weave & Echo

### How Flite uses Weave

Every Flite **controller** receives a full Weave scope. This means you can use
all of Weave's reactive primitives — `Value`, `Computed`, `Spring`, `Tween`,
`Show`, `ForValues`, `Suspense`, `ErrorBoundary`, `mount`, etc. — directly
inside controllers:

```lua
Flite.createController("ShopController", function(self)
    local shopService = self:useService("ShopService")
    local items = self:useServiceState("ShopService", "items")

    self:onStart(function()
        local Weave = require(ReplicatedStorage.Libraries.Weave)
        local playerGui = self:getPlayerGui()

        Weave.mount(playerGui, "Shop", function(scope)
            local search = scope:Value("")
            local filtered = scope:Computed(function(use)
                local query = use(search):lower()
                return use(items):filter(function(item)
                    return item.name:lower():find(query, 1, true) ~= nil
                end)
            end)

            return scope:Frame {
                scope:TextInput { [Weave.Bind "Text"] = search },
                scope:ForValues(filtered, function(s, item)
                    return s:TextButton {
                        Text = item.name .. " (" .. item.price .. ")",
                        [Weave.OnEvent "Activated"] = function()
                            shopService.purchase(item.id)
                                :andThen(function() print("Purchased!") end)
                                :catch(function(e) print("Failed:", e.message) end)
                        end,
                    }
                end),
            }
        end)
    end)
end)
```

### How Flite uses Echo

Flite's server-side state types (`MapState`, `ValueState`, `ChannelState`,
etc.) are built on `FrameworkSignal`, which wraps an Echo signal with network
replication. The `DomainBus` event system also uses Echo signals internally.

You don't need to interact with Echo directly — Flite abstracts it behind its
own state/signal API.

### Full stack dependency chain

```
Echo (pure-Luau signals)
 └─ Weave (reactive states + UI elements + rendering)
     └─ Flite (services + controllers + domains + networking + persistence)
```

When building a game with all three:
1. **Echo** powers all signal/event mechanics (transparent to you)
2. **Weave** provides the reactive UI layer (used inside controllers)
3. **Flite** provides the game structure (services, controllers, domains, networking)

You typically only `require` Flite and Weave directly. Echo is a transitive
dependency that "just works" underneath.

---

## License

[MIT](./LICENSE).
