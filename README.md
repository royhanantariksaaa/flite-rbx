# Flite

Flite is an open-source Roblox framework inspired by Express-style software
architecture and Knit. It helps developers structure Roblox games using
**Domains**, **Services**, **Views**, and **Controllers**, with reactive state,
typed service APIs, network replication, and persistence.

Built on top of [Weave](https://github.com/royhanantariksaaa/weave-rbx).

```lua
-- Server
local Flite = require(ReplicatedStorage.Libraries.Flite)

Flite.createService("PlotService", function(self: Flite.Service)
	self:useMapState("playerPlots")
	self:onPlayerAdded(function(player)
		self.playerPlots:set(player, { owned = false })
	end)
end)

Flite.start()
```

## Runtime requirements

Flite uses **absolute requires** to modules in `ReplicatedStorage.Libraries`.
At runtime, the following must be present:

- [`Weave`](https://github.com/royhanantariksaaa/weave-rbx) — `ReplicatedStorage.Libraries.Weave` (client controllers; also brings its own requirements)
- [`Echo`](https://github.com/royhanantariksaaa/echo-rbx) — `ReplicatedStorage.Libraries.Echo` (signals & state replication)
- [`WeaveKit`](https://github.com/royhanantariksaaa/weavekit-rbx) — `ReplicatedStorage.Libraries.WeaveKit` (only for the optional client `useTheme` hook)
- `Promise` — `ReplicatedStorage.Libraries.Promise`
- `Tween` — `ReplicatedStorage.Libraries.Tween`

`Weave`, `Echo`, and `WeaveKit` are their own libraries (see links). `Promise` and
`Tween` are leaf single-file utilities and are intentionally **not** vendored here.
When starting a fresh game, drop these files into `ReplicatedStorage.Libraries/`.

## Consume as a git submodule

From your game repo root (assuming `src/Shared` maps to `ReplicatedStorage`):

```sh
git submodule add https://github.com/royhanantariksaaa/echo-rbx.git src/Shared/Libraries/Echo
git submodule add https://github.com/royhanantariksaaa/weave-rbx.git src/Shared/Libraries/Weave
git submodule add https://github.com/royhanantariksaaa/weavekit-rbx.git src/Shared/Libraries/WeaveKit
git submodule add https://github.com/royhanantariksaaa/flite-rbx.git src/Shared/Libraries/Flite
```

This lands Flite at `ReplicatedStorage.Libraries.Flite`, matching what its own
requires expect.

## Standalone dev

Open the project in [Rojo](https://rojo.space):

```sh
rojo serve default.project.json
```

This serves Flite at `ReplicatedStorage.Libraries.Flite`. The sibling modules
listed above still need to be present for it to run.

## License

[MIT](./LICENSE).
