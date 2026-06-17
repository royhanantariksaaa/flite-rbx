--!optimize 2
--[=[
	@module DataStoreWrapper
	@within Flite

	DataStoreWrapper
	Lean session-based DataStore wrapper for Flite persistence.

	Replaces drop for Flite's use case. Collapses the 3-call pattern
	(StartSession + WaitForSession + View) into a single `startSession`
	that returns data directly.

	Usage:
		local DB = require(Flite.Server.DataStoreWrapper)

		local store = DB.createStore({
			Name = "PlayerData",
			Schema = {
				Initial = { Coins = 0, Gems = 0 },
				Migrations = {
					function(v1) return { Coins = v1.Coins, Gems = 0, Level = 1 } end,
				},
			},
		})

		local data = DB.startSession(store, "12345")
		data.Coins = 100
		DB.update(store, "12345", function(d) d.Coins = 200; return d end)
		DB.stopSession(store, "12345")
]=]

local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local DataStoreWrapper = {}

-- Studio mock fallback
local function getRealDataStore(name: string, scope: string?): DataStore
	return DataStoreService:GetDataStore(name, scope)
end

local function getMockDataStore(name: string, scope: string?): DataStore
	local mock = {}
	local store = {}

--[=[
	Reads a value from the in-memory DataStore fallback.
	@param key key
	@return any
]=]
	function mock:GetAsync(key)
		return store[key]
	end

--[=[
	Writes a value to the in-memory DataStore fallback.
	@param key key
	@param value value
]=]
	function mock:SetAsync(key, value)
		store[key] = value
	end

--[=[
	Updates a value in the in-memory DataStore fallback with a transform callback.
	@param key key
	@param transformFn transformFn
	@return any
]=]
	function mock:UpdateAsync(key, transformFn)
		local current = store[key]
		local new = transformFn(current, nil)
		if new == nil then
			return nil
		end
		store[key] = new
		return new
	end

--[=[
	Removes a value from the in-memory DataStore fallback.
	@param key key
]=]
	function mock:RemoveAsync(key)
		local val = store[key]
		store[key] = nil
		return val
	end

	return mock :: any
end

local getDataStore: (name: string, scope: string?) -> DataStore

if RunService:IsStudio() then
	local success = pcall(function()
		DataStoreService:GetDataStore("_")
	end)
	getDataStore = if success then getRealDataStore else getMockDataStore
else
	getDataStore = getRealDataStore
end

-- DataStore helpers with retry
local function dsGetAsync(datastore: DataStore, key: string): (boolean, any)
	local success, result = pcall(datastore.GetAsync, datastore, key)
	if success then
		return true, result
	end

	local success2, result2 = pcall(datastore.GetAsync, datastore, key)
	if success2 then
		return true, result2
	end

	return false, result2
end

local function dsUpdateAsync(datastore: DataStore, key: string, transformFn: (any, any) -> any?): (boolean, any, any)
	local success, result, info = pcall(datastore.UpdateAsync, datastore, key, transformFn)
	if success then
		return true, result, info
	end

	local success2, result2, info2 = pcall(datastore.UpdateAsync, datastore, key, transformFn)
	if success2 then
		return true, result2, info2
	end

	return false, nil, nil
end

-- Schema migrations
local function migrateData(schema: { Initial: any, Migrations: { (any) -> any } }, data: any, currentVersion: number): any?
	if data == nil then
		return nil
	end

	for i = currentVersion + 1, #schema.Migrations do
		local ok, migrated = pcall(schema.Migrations[i], data)
		if not ok then
			warn(`[Flite.DataStoreWrapper] Migration {i} failed: {migrated}`)
			return nil
		end
		data = migrated
	end

	return data
end

-- Deep equality (for dirty tracking)
local function deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= type(b) then
		return false
	end
	if type(a) ~= "table" then
		return false
	end

	for k, v in pairs(a) do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k in pairs(b) do
		if a[k] == nil then
			return false
		end
	end

	return true
end

local function deepClone(t: any): any
	if type(t) ~= "table" then
		return t
	end
	local clone = {}
	for k, v in pairs(t) do
		clone[k] = deepClone(v)
	end
	return clone
end

-- Store type
export type Store = {
	Source: DataStore,
	Schema: { Initial: any, Migrations: { (any) -> any } },

	-- Per-key session state
	_sessions: { [string]: {
		data: any,
		dirty: boolean,
		originalData: any?,
		observers: { (newData: any, oldData: any) -> () },
	} },

	-- Periodic auto-flush
	_flushInterval: number,
	_flushLoop: thread?,
	_flushAlive: boolean,
}

-- Public API
--[=[
	Create a store with schema and optional migrations.

	@param opts { Name: string, Scope: string?, Schema: any, FlushInterval: number? } -- store configuration
	@return Store -- session-aware DataStore wrapper
]=]
function DataStoreWrapper.createStore(opts: {
	Name: string,
	Scope: string?,
	Schema: { Initial: any, Migrations: { (any) -> any } },
	FlushInterval: number?,
}): Store
	local store: Store = {
		Source = getDataStore(opts.Name, opts.Scope),
		Schema = opts.Schema,
		_sessions = {},
		_flushInterval = opts.FlushInterval or 60,
		_flushLoop = nil,
		_flushAlive = true,
	}

	-- Start periodic auto-flush loop
	store._flushLoop = task.spawn(function()
		while store._flushAlive do
			task.wait(store._flushInterval)
			if not store._flushAlive then
				break
			end
			for key in store._sessions do
				task.spawn(function()
					DataStoreWrapper.flush(store, key)
				end)
			end
		end
	end)

	-- Auto-flush all sessions on server shutdown
	game:BindToClose(function()
		store._flushAlive = false
		for key in store._sessions do
			task.spawn(function()
				DataStoreWrapper.stopSession(store, key)
			end)
		end
	end)

	return store
end

--[=[
	Load data from DataStore, apply migrations, cache it, and return it directly.
	Returns the cached data table. If the key has no data, returns a clone of
	Schema.Initial.

	This replaces: drop.StartSession + drop.WaitForSession + drop.View

	@param store Store -- store returned by `createStore`
	@param key string -- session key
	@return { [string]: any } -- cached mutable session data
]=]
--[=[
	Starts or resumes a simple session payload for a DataStore key.
	@param store store: Store
	@param key key: string
	@return { [string]: any }
]=]
function DataStoreWrapper.startSession(store: Store, key: string): { [string]: any }
	if store._sessions[key] then
		return store._sessions[key].data
	end

	local session = {
		data = nil,
		dirty = false,
		originalData = nil,
		observers = {},
	}

	-- Read from DataStore
	local success, record = dsGetAsync(store.Source, key)

	if success and record ~= nil then
		local version = record._version or 0
		local migrated = migrateData(store.Schema, record.data or record, version)
		if migrated ~= nil then
			session.data = migrated
		else
			-- Migration failed, fall back to initial
			session.data = deepClone(store.Schema.Initial)
		end
	else
		-- No data yet, use initial
		session.data = deepClone(store.Schema.Initial)
	end

	session.originalData = deepClone(session.data)
	store._sessions[key] = session

	return session.data
end

--[=[
	Get the current cached session data. Returns nil if no active session.

	@param store Store -- store returned by `createStore`
	@param key string -- session key
	@return { [string]: any }? -- cached session data, if active
]=]
function DataStoreWrapper.getSessionData(store: Store, key: string): { [string]: any }?
	local session = store._sessions[key]
	if session then
		return session.data
	end
	return nil
end

--[=[
	Update cached data with a transform function. Marks the session as dirty.
	Calls observers after the update.

	@param store Store -- store returned by `createStore`
	@param key string -- session key
	@param transformFn (any) -> any? -- receives cloned data and returns replacement data
]=]
function DataStoreWrapper.update(store: Store, key: string, transformFn: (any) -> any?)
	local session = store._sessions[key]
	if not session then
		error(`[Flite.DataStoreWrapper] No active session for key "{key}"`)
	end

	local oldData = session.data
	local newData = transformFn(deepClone(session.data))

	if newData == nil then
		return
	end

	session.data = newData
	session.dirty = true

	-- Notify observers
	for _, observer in session.observers do
		task.defer(observer, newData, oldData)
	end
end

--[=[
	Observe changes to session data. Callback fires on each update.

	@param store Store -- store returned by `createStore`
	@param key string -- session key
	@param callback (any, any) -> () -- receives new and old data
	@return () -> () -- disconnect function
]=]
function DataStoreWrapper.observe(store: Store, key: string, callback: (newData: any, oldData: any) -> ()): () -> ()
	local session = store._sessions[key]
	if not session then
		error(`[Flite.DataStoreWrapper] No active session for key "{key}"`)
	end

	table.insert(session.observers, callback)

	return function()
		for i, obs in ipairs(session.observers) do
			if obs == callback then
				table.remove(session.observers, i)
				break
			end
		end
	end
end

--[=[
	Flush dirty data to DataStore. Does not end the session.
	Returns true if flushed or no changes, false if write failed.

	@param store Store -- store returned by `createStore`
	@param key string -- session key
	@return boolean -- true when data is clean or saved successfully
]=]
function DataStoreWrapper.flush(store: Store, key: string): boolean
	local session = store._sessions[key]
	if not session then
		return true
	end

	if not session.dirty then
		return true
	end

	local dataToSave = {
		_version = #store.Schema.Migrations,
		data = session.data,
	}

	local success = dsUpdateAsync(store.Source, key, function()
		return dataToSave
	end)

	if success then
		session.dirty = false
		session.originalData = deepClone(session.data)
	end

	return success
end

--[=[
	Flush dirty data and end the session.

	@param store Store -- store returned by `createStore`
	@param key string -- session key
]=]
function DataStoreWrapper.stopSession(store: Store, key: string)
	local session = store._sessions[key]
	if not session then
		return
	end

	-- Flush if dirty
	if session.dirty then
		DataStoreWrapper.flush(store, key)
	end

	-- Clear session
	session.observers = {}
	store._sessions[key] = nil
end

return DataStoreWrapper
