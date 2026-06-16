--[[
	DataStoreInbox
	Optional cross-server messaging for Flite persistence.

	Provides a per-player message queue that works even when the player is offline.
	Messages are stored in a dedicated DataStore (storeName .. "__inbox") and
	delivered via MessagingService nudges when the player is online.

	This is extracted from drop's inbox.luau as a standalone opt-in module.

	Usage:
		local Inbox = require(Flite.Server.DataStoreInbox)

		local inbox = Inbox.create("PlayerData")
		Inbox.onMessage(inbox, "giftReceived", function(envelope)
			print("Player got a gift from:", envelope.Sender)
		end)

		-- From another server:
		Inbox.sendasync(inbox, "12345", "giftReceived", { itemId = 42 }, "99999")

		-- On session start:
		Inbox.subscribe(inbox, "PlayerData", "12345")
		Inbox.processasync(inbox, "PlayerData", "12345")
]]

local HttpService = game:GetService("HttpService")
local MessagingService = game:GetService("MessagingService")
local DataStoreService = game:GetService("DataStoreService")
local RunService = game:GetService("RunService")

local DataStoreInbox = {}

-- ── Studio mock fallback ───────────────────────────────

local function getRealDataStore(name: string, scope: string?): DataStore
	return DataStoreService:GetDataStore(name, scope)
end

local function getMockDataStore(name: string, scope: string?): DataStore
	local mock = {}
	local store = {}

	function mock:GetAsync(key)
		return store[key]
	end

	function mock:SetAsync(key, value)
		store[key] = value
	end

	function mock:UpdateAsync(key, transformFn)
		local current = store[key]
		local new = transformFn(current, nil)
		if new == nil then
			return nil
		end
		store[key] = new
		return new
	end

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

-- ── DataStore helpers ──────────────────────────────────

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

-- ── Types ──────────────────────────────────────────────

export type Envelope = {
	Id: string,
	Kind: string,
	Data: any,
	Created: number,
	Sender: string?,
}

type InboxRecord = {
	messages: { [string]: Envelope },
}

export type InboxController = {
	Source: DataStore,
	StoreName: string,
	Handlers: { [string]: (envelope: Envelope) -> () },
	Subscriptions: { [string]: RBXScriptConnection },
	Processing: { [string]: boolean },
}

-- ── Helpers ────────────────────────────────────────────

local function emptyRecord(): InboxRecord
	return { messages = {} }
end

local function topicFor(storeName: string, key: string): string
	return `flite_inbox_{storeName}_{key}`
end

local function inboxKey(key: string): string
	return `{key}_inbox`
end

-- ── Public API ─────────────────────────────────────────

--[[
	Create a new InboxController for a store.
]]
function DataStoreInbox.create(storeName: string, scope: string?): InboxController
	local controller: InboxController = {
		Source = getDataStore(storeName .. "__inbox", scope),
		StoreName = storeName,
		Handlers = {},
		Subscriptions = {},
		Processing = {},
	}
	return controller
end

--[[
	Send a message to a target key's inbox. Cross-server safe.
	Yields until the write completes.
]]
function DataStoreInbox.sendasync(
	controller: InboxController,
	targetKey: string,
	kind: string,
	data: any,
	sender: string?
)
	local envelope: Envelope = {
		Id = HttpService:GenerateGUID(false),
		Kind = kind,
		Data = data,
		Created = os.time(),
		Sender = sender,
	}

	local dsKey = inboxKey(targetKey)
	local success = dsUpdateAsync(controller.Source, dsKey, function(existing: InboxRecord?)
		local rec = existing or emptyRecord()
		rec.messages[envelope.Id] = envelope
		return rec
	end)

	if not success then
		warn(`[Flite.DataStoreInbox] Failed to send inbox message to {targetKey}`)
		return
	end

	-- Nudge via MessagingService (best-effort)
	local topic = topicFor(controller.StoreName, targetKey)
	pcall(function()
		MessagingService:PublishAsync(topic, { envelopeId = envelope.Id })
	end)
end

--[[
	Register a handler for a message kind.
]]
function DataStoreInbox.onMessage(controller: InboxController, kind: string, handler: (envelope: Envelope) -> ())
	if controller.Handlers[kind] then
		error(`Handler already registered for kind "{kind}"`)
	end

	controller.Handlers[kind] = handler
end

--[[
	Process all pending messages for a key.
	Reads the inbox, invokes handlers, removes processed envelopes.
]]
function DataStoreInbox.processasync(controller: InboxController, _storeName: string, key: string)
	if controller.Processing[key] then
		return
	end
	controller.Processing[key] = true

	local dsKey = inboxKey(key)
	local success, record = dsGetAsync(controller.Source, dsKey)

	if success and record and record.messages then
		for id, envelope in record.messages do
			local handler = controller.Handlers[envelope.Kind]

			if handler then
				local ok, err = pcall(function()
					handler(envelope)
				end)
				if ok then
					-- Remove processed envelope
					task.defer(function()
						dsUpdateAsync(controller.Source, dsKey, function(r: InboxRecord?)
							if r == nil then
								return nil
							end
							r.messages[id] = nil
							return r
						end)
					end)
				else
					warn(`[Flite.DataStoreInbox] Handler error for kind "{envelope.Kind}": {err}`)
				end
			else
				warn(`[Flite.DataStoreInbox] No handler registered for kind "{envelope.Kind}", skipping`)
			end
		end
	end

	controller.Processing[key] = nil
end

--[[
	Subscribe to MessagingService nudges for a key.
	Call this when a session starts.
]]
function DataStoreInbox.subscribe(controller: InboxController, storeName: string, key: string)
	if controller.Subscriptions[key] then
		return
	end

	local topic = topicFor(storeName, key)
	local ok, connection = pcall(function()
		return MessagingService:SubscribeAsync(topic, function()
			task.defer(DataStoreInbox.processasync, controller, storeName, key)
		end)
	end)

	if ok and connection then
		controller.Subscriptions[key] = connection
	end
end

--[[
	Unsubscribe from MessagingService nudges for a key.
	Call this when a session stops.
]]
function DataStoreInbox.unsubscribe(controller: InboxController, key: string)
	local connection = controller.Subscriptions[key]
	if connection then
		connection:Disconnect()
		controller.Subscriptions[key] = nil
	end
end

return DataStoreInbox
