--!optimize 2
--[=[
	@module HookRegistration
	@within Flite

	HookRegistration

	Shared universal hooks available on Controllers, Services, and Domains.
	All hooks are implemented ONCE here and bound to all scopes automatically.
]=]

local HookRegistration = {}

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Tween = require(ReplicatedStorage.Libraries.Tween)

local function trackCharacters(rp: any, players: {Player})
	local tracked = {}
	local connections = {}

	local function refreshFilter()
		rp.FilterDescendantsInstances = table.clone(tracked)
	end

	for _, player in players do
		if player.Character then
			table.insert(tracked, player.Character)
		end
		table.insert(connections, player.CharacterAdded:Connect(function(char)
			table.insert(tracked, char)
			refreshFilter()
		end))
		table.insert(connections, player.CharacterRemoving:Connect(function(char)
			local idx = table.find(tracked, char)
			if idx then table.remove(tracked, idx) end
			refreshFilter()
		end))
	end

	refreshFilter()
	return connections
end

--[=[
	Installs cleanup and observer helper methods on a builder scope.
	@param scope scope: any
	@param addCleanup Stores a cleanup callback on the owning builder.
]=]
function HookRegistration.bind(scope: any, addCleanup: (() -> ()) -> ())
	-- === UNIVERSAL HOOKS ===
	function scope:useTimeout(fn: () -> (), delayMs: number)
		local connection = task.delay(delayMs / 1000, fn)
		addCleanup(function()
			task.cancel(connection)
		end)
		return connection
	end

	function scope:useInterval(fn: () -> (), intervalMs: number)
		local connection = task.spawn(function()
			while true do
				task.wait(intervalMs / 1000)
				fn()
			end
		end)
		addCleanup(function()
			task.cancel(connection)
		end)
		return connection
	end

	do
		function scope:useTween(target: any, info: TweenInfo, goals: {[string]: any}, callback: (() -> ())?)
			local tween = Tween.Tween(target, info, goals, callback)
			addCleanup(function()
				tween.Cancel()
			end)
			return tween
		end
	end

	function scope:useDebounce(fn: (...any) -> (), delayMs: number)
		local lastCall = 0
		local pending = nil
		addCleanup(function()
			if pending then task.cancel(pending) end
		end)
		return function(...)
			local now = os.clock() * 1000
			local args = table.pack(...)
			if pending then task.cancel(pending) end
			pending = task.delay(delayMs / 1000, function()
				lastCall = os.clock() * 1000
				pending = nil
				fn(table.unpack(args))
			end)
		end
	end

	function scope:useThrottle(fn: (...any) -> (), intervalMs: number)
		local lastCall = 0
		return function(...)
			local now = os.clock() * 1000
			if now - lastCall >= intervalMs then
				lastCall = now
				fn(...)
			end
		end
	end

	function scope:useRef(initialValue: any?)
		return { current = initialValue }
	end

	function scope:useMemo(fn: () -> any, dependencies: {any})
		local value = nil
		local lastDeps = nil
		local function depsEqual(a, b)
			if #a ~= #b then return false end
			for i = 1, #a do if a[i] ~= b[i] then return false end end
			return true
		end
		return function()
			local currentDeps = dependencies
			if not lastDeps or not depsEqual(lastDeps, currentDeps) then
				lastDeps = table.clone(currentDeps)
				value = fn()
			end
			return value
		end
	end

	function scope:useEffect(fn: () -> (() -> ())?, dependencies: {any})
		local cleanupFn = nil
		local lastDeps = nil
		local function depsEqual(a, b)
			if #a ~= #b then return false end
			for i = 1, #a do if a[i] ~= b[i] then return false end end
			return true
		end
		local function run()
			local currentDeps = dependencies
			if not lastDeps or not depsEqual(lastDeps, currentDeps) then
				if cleanupFn then cleanupFn() end
				lastDeps = table.clone(currentDeps)
				cleanupFn = fn()
			end
		end
		addCleanup(function()
			if cleanupFn then cleanupFn() end
		end)
		return run
	end

	-- === ADVANCED HOOKS ===
	function scope:useBatch(waitMs: number)
		local pending = {}
		local scheduled = nil
		local function flush()
			scheduled = nil
			for _, fn in pending do fn() end
			table.clear(pending)
		end
		addCleanup(function()
			if scheduled then task.cancel(scheduled) end
		end)
		return function(fn: () -> ())
			table.insert(pending, fn)
			if not scheduled then
				scheduled = task.delay(waitMs / 1000, flush)
			end
		end
	end

	function scope:useRollback(state: any, restoreValue: any)
		local original = state:Get()
		addCleanup(function()
			state:Set(original)
		end)
		return function()
			state:Set(restoreValue)
		end
	end

	function scope:useSpring(initialValue: number, stiffness: number?, damping: number?)
		local st = stiffness or 180
		local dmp = damping or 26
		local vel = 0
		local current = initialValue
		local goal = initialValue
		local conn = game:GetService("RunService").Heartbeat:Connect(function(dt)
			local force = st * (goal - current)
			vel = (vel + force * dt) * math.clamp(1 - dmp * dt, 0, 1)
			current = current + vel * dt
		end)
		addCleanup(function() conn:Disconnect() end)
		return {
			set = function(v) goal = v end,
			get = function() return current end,
			immediate = function(v) goal = v current = v vel = 0 end
		}
	end

	function scope:useCache(ttlMs: number, resolver: (...any) -> any)
		local cache = {}
		return function(...)
			local key = table.concat({...}, "\0")
			local entry = cache[key]
			if entry and os.clock() * 1000 - entry.time < ttlMs then
				return entry.value
			end
			local value = resolver(...)
			cache[key] = { value = value, time = os.clock() * 1000 }
			return value
		end
	end

	function scope:useOnce(key: string, fn: () -> ())
		local ran = false
		return function()
			if not ran then
				ran = true
				fn()
			end
		end
	end

	function scope:usePrevious(value: any)
		local ref = self:useRef(nil)
		local prev = ref.current
		ref.current = value
		return prev
	end

	-- === WORLD QUERY HOOKS ===
	function scope:useRaycast(params: RaycastParams?, trackPlayers: {Player}?)
		local rp = params or RaycastParams.new()
		rp.RespectCanCollide = true

		if trackPlayers then
			local conns = trackCharacters(rp, trackPlayers)
			for _, conn in conns do
				addCleanup(function() conn:Disconnect() end)
			end
		end

		return function(origin: Vector3, direction: Vector3, maxDistance: number?): RaycastResult?
			return workspace:Raycast(origin, direction.Unit * (maxDistance or 1000), rp)
		end
	end

	function scope:useBlockcast(params: RaycastParams?, trackPlayers: {Player}?)
		local rp = params or RaycastParams.new()

		if trackPlayers then
			local conns = trackCharacters(rp, trackPlayers)
			for _, conn in conns do
				addCleanup(function() conn:Disconnect() end)
			end
		end

		return function(size: Vector3, origin: Vector3, direction: Vector3, maxDistance: number?): RaycastResult?
			return workspace:Blockcast(CFrame.new(origin), size, direction.Unit * (maxDistance or 1000), rp)
		end
	end

	function scope:useShapecast(shape: any, params: RaycastParams?, trackPlayers: {Player}?)
		local rp = params or RaycastParams.new()

		if trackPlayers then
			local conns = trackCharacters(rp, trackPlayers)
			for _, conn in conns do
				addCleanup(function() conn:Disconnect() end)
			end
		end

		return function(cframe: CFrame, direction: Vector3, maxDistance: number?): RaycastResult?
			if shape:IsA("Part") then
				return workspace:Shapecast(shape, cframe, direction.Unit * (maxDistance or 1000), rp)
			else
				return workspace:Spherecast(cframe.Position, shape, direction.Unit * (maxDistance or 1000), rp)
			end
		end
	end

	function scope:useSpherecast(radius: number, params: RaycastParams?, trackPlayers: {Player}?)
		local rp = params or RaycastParams.new()

		if trackPlayers then
			local conns = trackCharacters(rp, trackPlayers)
			for _, conn in conns do
				addCleanup(function() conn:Disconnect() end)
			end
		end

		return function(origin: Vector3, direction: Vector3, maxDistance: number?): RaycastResult?
			return workspace:Spherecast(origin, radius, direction.Unit * (maxDistance or 1000), rp)
		end
	end

	function scope:useBoxcast(size: Vector3, params: RaycastParams?, trackPlayers: {Player}?)
		local rp = params or RaycastParams.new()

		if trackPlayers then
			local conns = trackCharacters(rp, trackPlayers)
			for _, conn in conns do
				addCleanup(function() conn:Disconnect() end)
			end
		end

		return function(cframe: CFrame, direction: Vector3, maxDistance: number?): RaycastResult?
			return workspace:Blockcast(cframe, size, direction.Unit * (maxDistance or 1000), rp)
		end
	end

	function scope:useTouched(target: Instance | () -> CFrame, radius: number?, params: OverlapParams?, trackPlayers: {Player}?)
		local rp = params or OverlapParams.new()
		rp.RespectCanCollide = false
		local enterCallbacks = {}
		local exitCallbacks = {}
		local lastHits = {}

		if trackPlayers then
			local conns = trackCharacters(rp, trackPlayers)
			for _, conn in conns do
				addCleanup(function() conn:Disconnect() end)
			end
		end

		local getCFrame: () -> CFrame
		if typeof(target) == "Instance" then
			getCFrame = function() return target.CFrame end
		elseif type(target) == "function" then
			getCFrame = target
		else
			error("useTouched target must be an Instance or function that returns CFrame")
		end

		local detectionRadius = radius or 0.5

		local conn = game:GetService("RunService").Heartbeat:Connect(function()
			local cf = getCFrame()
			local parts = workspace:GetPartBoundsInRadius(cf.Position, detectionRadius, rp)
			if #parts > 0 then
				-- print(`[useTouched] Found {#parts} parts within {detectionRadius} studs`)
			end
			local current = {}

			for _, part in parts do
				current[part] = true
				if not lastHits[part] then
					-- print(`[useTouched] Part entered: {part.Name}, {target}`)
					for _, cb in enterCallbacks do
						task.spawn(cb, part, true)
					end
				end
			end

			for part in lastHits do
				if not current[part] then
					-- print(`[useTouched] Part exited: {part.Name}`)
					for _, cb in exitCallbacks do
						task.spawn(cb, part, false)
					end
				end
			end

			lastHits = current
		end)

		addCleanup(function() conn:Disconnect() end)

		return {
			Connect = function(_, callback: (otherPart: Instance, isEntering: boolean) -> ())
				table.insert(enterCallbacks, callback)
				table.insert(exitCallbacks, callback)
				return {
					Disconnect = function()
						local idx = table.find(enterCallbacks, callback)
						if idx then table.remove(enterCallbacks, idx) end
						idx = table.find(exitCallbacks, callback)
						if idx then table.remove(exitCallbacks, idx) end
					end
				}
			end,
			Once = function(self, callback: (otherPart: Instance, isEntering: boolean) -> ())
				local connection
				connection = self:Connect(function(part, isEntering)
					connection:Disconnect()
					callback(part, isEntering)
				end)
				return connection
			end,
			DisconnectAll = function()
				table.clear(enterCallbacks)
				table.clear(exitCallbacks)
			end
		}
	end

	function scope:observeTag(tag: string, callback: (Instance, boolean) -> ())
		local observed = {}

		local function emit(inst: Instance, isTagged: boolean)
			task.spawn(callback, inst, isTagged)
		end

		local function handleAdded(inst: Instance)
			if observed[inst] then
				return
			end
			observed[inst] = true
			emit(inst, true)
		end

		local function handleRemoved(inst: Instance)
			if not observed[inst] then
				return
			end
			observed[inst] = nil
			emit(inst, false)
		end

		for _, inst in CollectionService:GetTagged(tag) do
			handleAdded(inst)
		end

		local addedConnection = CollectionService:GetInstanceAddedSignal(tag):Connect(handleAdded)
		local removedConnection = CollectionService:GetInstanceRemovedSignal(tag):Connect(handleRemoved)

		addCleanup(function()
			addedConnection:Disconnect()
			removedConnection:Disconnect()
			table.clear(observed)
		end)
	end

	function scope:useTagged(tag: string, onAdded: (Instance) -> (), onRemoved: ((Instance) -> ())?)
		scope:observeTag(tag, function(inst: Instance, isTagged: boolean)
			if isTagged then
				onAdded(inst)
			elseif onRemoved then
				onRemoved(inst)
			end
		end)
	end

	function scope:getTagged(tag: string): {Instance}
		return CollectionService:GetTagged(tag)
	end

	function scope:hasTag(instance: Instance, tag: string): boolean
		return CollectionService:HasTag(instance, tag)
	end
end

return HookRegistration
