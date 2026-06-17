--[=[
	@module MetadataPublisher
	@within Flite

	Publishes service metadata and schemas for client proxy discovery.
]=]

local SchemaPublisher = require(script.Parent.Parent.Parent.Shared.SchemaPublisher)
local t = require(script.Parent.Parent.Parent.Shared.t)
local HttpService = game:GetService("HttpService")

local MetadataPublisher = {}

type PublishOptions = {
	manifestOnly: boolean?,
}

--[=[
	Publishes service metadata onto replicated Instances for client discovery.
	@param serviceFolder serviceFolder: Folder
	@param states states: any
	@param signals signals: any
	@param exposedMethods exposedMethods: any
	@param options options: PublishOptions?
]=]
function MetadataPublisher.publish(serviceFolder: Folder, states: any, signals: any, exposedMethods: any, options: PublishOptions?)
	local publishOptions = options or {}
	local manifestOnly = publishOptions.manifestOnly == true
	local replicatedStateFields = {}
	local fieldDefaults = {}

	for fieldName, state in states do
		if state._replicateToClients or state._default ~= nil then
			table.insert(replicatedStateFields, fieldName)
		end
		if state._default ~= nil then
			fieldDefaults[fieldName] = state._default
			if not manifestOnly then
				if type(state._default) == "table" then
					serviceFolder:SetAttribute(fieldName, "JSN:" .. HttpService:JSONEncode(state._default))
				else
					pcall(function()
						serviceFolder:SetAttribute(fieldName, state._default)
					end)
				end
			end
		end
	end

	if not manifestOnly and next(fieldDefaults) then
		-- Compact startup metadata path for clients. Legacy per-field attributes remain for compatibility.
		serviceFolder:SetAttribute("_fieldDefaults", HttpService:JSONEncode(fieldDefaults))
	end

	if not manifestOnly and #replicatedStateFields > 0 then
		serviceFolder:SetAttribute("_stateFields", HttpService:JSONEncode(replicatedStateFields))
	end

	local signalNames = {}
	local signalSchemas = {}
	local unreliableSignals = {}
	for signalName, signal in signals do
		table.insert(signalNames, signalName)
		if signal._globalEvent and typeof(signal._globalEvent) == "Instance" and signal._globalEvent:IsA("UnreliableRemoteEvent") then
			table.insert(unreliableSignals, signalName)
		end
		if signal._schema then
			local schemasFound = {}
			for i, schema in ipairs(signal._schema) do
				local def = t.dump(schema)
				schemasFound[i] = def or "UnknownSchema"
			end
			signalSchemas[signalName] = schemasFound
		end
	end

	if not manifestOnly and #signalNames > 0 then
		serviceFolder:SetAttribute("_signals", HttpService:JSONEncode(signalNames))
	end
	if not manifestOnly and #unreliableSignals > 0 then
		serviceFolder:SetAttribute("_unreliableSignals", HttpService:JSONEncode(unreliableSignals))
	end

	if not manifestOnly then
		SchemaPublisher.publishMethodSchemas(serviceFolder, exposedMethods)
	end

	if not manifestOnly and next(signalSchemas) then
		serviceFolder:SetAttribute("_signalSchemas", HttpService:JSONEncode(signalSchemas))
	end

	local manifest = {
		fieldDefaults = fieldDefaults,
		stateFields = replicatedStateFields,
		signals = signalNames,
		unreliableSignals = unreliableSignals,
		signalSchemas = signalSchemas,
		methods = {},
		methodSchemas = {},
		methodReturnSchemas = {},
	}

	if manifestOnly then
		for methodName, _ in pairs(exposedMethods) do
			table.insert(manifest.methods, methodName)
		end

		table.sort(manifest.methods)

		for methodName, config in pairs(exposedMethods) do
			if type(config) == "table" and type(config.args) == "table" and #config.args > 0 then
				local schemasFound = {}
				local isComplete = true
				for i, schema in ipairs(config.args) do
					local def = t.dump(schema)
					if def then
						schemasFound[i] = def
					else
						isComplete = false
						break
					end
				end
				if isComplete then
					manifest.methodSchemas[methodName] = schemasFound
				end
			end
		end

		for methodName, config in pairs(exposedMethods) do
			if type(config) == "table" and type(config.returns) == "table" and #config.returns > 0 then
				local schemasFound = {}
				local isComplete = true
				for i, schema in ipairs(config.returns) do
					local def = t.dump(schema)
					if def then
						schemasFound[i] = def
					else
						isComplete = false
						break
					end
				end
				if isComplete then
					manifest.methodReturnSchemas[methodName] = schemasFound
				end
			end
		end
	else
		local encodedMethods = serviceFolder:GetAttribute("_methods")
		if type(encodedMethods) == "string" then
			local ok, decoded = pcall(function()
				return HttpService:JSONDecode(encodedMethods)
			end)
			if ok and type(decoded) == "table" then
				manifest.methods = decoded
			end
		end

		local encodedMethodSchemas = serviceFolder:GetAttribute("_methodSchemas")
		if type(encodedMethodSchemas) == "string" then
			local ok, decoded = pcall(function()
				return HttpService:JSONDecode(encodedMethodSchemas)
			end)
			if ok and type(decoded) == "table" then
				manifest.methodSchemas = decoded
			end
		end

		local encodedMethodReturnSchemas = serviceFolder:GetAttribute("_methodReturnSchemas")
		if type(encodedMethodReturnSchemas) == "string" then
			local ok, decoded = pcall(function()
				return HttpService:JSONDecode(encodedMethodReturnSchemas)
			end)
			if ok and type(decoded) == "table" then
				manifest.methodReturnSchemas = decoded
			end
		end
	end

	serviceFolder:SetAttribute("_manifest", HttpService:JSONEncode(manifest))

	return fieldDefaults
end

return MetadataPublisher
