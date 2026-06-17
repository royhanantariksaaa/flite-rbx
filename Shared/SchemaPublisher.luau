--!optimize 2
--[=[
	@module SchemaPublisher
	@within Flite

	SchemaPublisher
	Shared helper for extracting and publishing method schemas to Attributes.
]=]

local HttpService = game:GetService("HttpService")
local t = require(script.Parent.t)

local SchemaPublisher = {}

--[=[
	Extracts a flat list of exposed method names.
]=]
function SchemaPublisher.extractMethodNames(exposedMethods: { [string]: any }): { string }
	local methodNames = {}
	for methodName in exposedMethods do
		table.insert(methodNames, methodName)
	end
	return methodNames
end

--[=[
	Extracts method schemas from an exposed methods table.
	Only methods that contain at least one valid schema are included.
]=]
function SchemaPublisher.extractMethodSchemas(exposedMethods: { [string]: any }): { [string]: { [number]: string } }
	local methodSchemas = {}

	for methodName, config in exposedMethods do
		if type(config) == "table" and type(config.args) == "table" then
			local schemasFound = {}
			local hasSchema = false
			for i, v in ipairs(config.args) do
				if type(v) == "table" and type(v.validate) == "function" and v._def then
					schemasFound[i] = t.dump(v) or "UnknownSchema"
					hasSchema = true
				else
					schemasFound[i] = "UnknownSchema"
				end
			end

			if hasSchema then
				methodSchemas[methodName] = schemasFound
			end
		end
	end

	return methodSchemas
end

--[=[
	Extracts serializable return schemas from exposed method metadata.
	@param exposedMethods exposedMethods: { [string]: any }
]=]
function SchemaPublisher.extractMethodReturnSchemas(exposedMethods: { [string]: any }): { [string]: { [number]: string } }
	local methodReturnSchemas = {}

	for methodName, config in exposedMethods do
		if type(config) == "table" and type(config.returns) == "table" then
			local schemasFound = {}
			local hasSchema = false
			for i, v in ipairs(config.returns) do
				if type(v) == "table" and type(v.validate) == "function" and v._def then
					schemasFound[i] = t.dump(v) or "UnknownSchema"
					hasSchema = true
				else
					schemasFound[i] = "UnknownSchema"
				end
			end

			if hasSchema then
				methodReturnSchemas[methodName] = schemasFound
			end
		end
	end

	return methodReturnSchemas
end

--[=[
	Publishes extracted method schemas to the `_methodSchemas` attribute.
]=]
function SchemaPublisher.publishMethodSchemas(target: Instance, exposedMethods: { [string]: any })
	local methodNames = SchemaPublisher.extractMethodNames(exposedMethods)
	if #methodNames > 0 then
		target:SetAttribute("_methods", HttpService:JSONEncode(methodNames))
	end

	local methodSchemas = SchemaPublisher.extractMethodSchemas(exposedMethods)
	if next(methodSchemas) then
		target:SetAttribute("_methodSchemas", HttpService:JSONEncode(methodSchemas))
	end

	local methodReturnSchemas = SchemaPublisher.extractMethodReturnSchemas(exposedMethods)
	if next(methodReturnSchemas) then
		target:SetAttribute("_methodReturnSchemas", HttpService:JSONEncode(methodReturnSchemas))
	end
end

return SchemaPublisher
