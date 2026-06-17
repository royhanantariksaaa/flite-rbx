--[=[
	@module t
	@within Flite

	Strict schema validator and binary Buffer serialization library.
	Supports generating primitive generic types, struct mapping, and Roblox primitives.

	Every schema object returns:
		schema.validate(value) -> boolean
		schema.getSize(value) -> number (bytes)
		schema.pack(buffer, cursor, value, instances) -> newCursor
		schema.unpack(buffer, cursor, instances) -> (value, newCursor)
]=]

local t = {}

-- Helper to quickly return fixed sizes
local function fixedSize(bytes: number)
	return function() return bytes end
end

-- ============================================================================
-- PRIMITIVES
-- ============================================================================

t.number = {
	name = "number",
	_def = "number",
	validate = function(v) return type(v) == "number" end,
	getSize = fixedSize(8), -- f64
	pack = function(b, c, v) buffer.writef64(b, c, v); return c + 8 end,
	unpack = function(b, c) return buffer.readf64(b, c), c + 8 end,
}

t.string = {
	name = "string",
	_def = "string",
	validate = function(v) return type(v) == "string" and #v <= 65535 end,
	getSize = function(v) return 2 + #v end, -- u16 length + string
	pack = function(b, c, v)
		local len = #v
		buffer.writeu16(b, c, len)
		buffer.writestring(b, c + 2, v, len)
		return c + 2 + len
	end,
	unpack = function(b, c)
		local len = buffer.readu16(b, c)
		local str = buffer.readstring(b, c + 2, len)
		return str, c + 2 + len
	end,
}

t.boolean = {
	name = "boolean",
	_def = "boolean",
	validate = function(v) return type(v) == "boolean" end,
	getSize = fixedSize(1), -- u8
	pack = function(b, c, v) buffer.writeu8(b, c, v and 1 or 0); return c + 1 end,
	unpack = function(b, c) return buffer.readu8(b, c) == 1, c + 1 end,
}

t.any = {
	name = "any",
	_def = "any",
	validate = function() return true end,
	-- Unsupported for native network packing alone unless enveloped with a type tag (not supported natively here)
	-- To send 'any', users should use t.instance or generic remote bindings.
	getSize = fixedSize(0),
	pack = function(b, c) return c end,
	unpack = function(b, c) return nil, c end, 
}

-- ============================================================================
-- SIZED INTEGERS (For strict byte packing optimizations)
-- ============================================================================

t.uint8 = {
	name = "uint8",
	_def = "uint8",
	validate = function(v) return type(v) == "number" and v >= 0 and v <= 255 and v % 1 == 0 end,
	getSize = fixedSize(1),
	pack = function(b, c, v) buffer.writeu8(b, c, v); return c + 1 end,
	unpack = function(b, c) return buffer.readu8(b, c), c + 1 end,
}

t.int8 = {
	name = "int8",
	_def = "int8",
	validate = function(v) return type(v) == "number" and v >= -128 and v <= 127 and v % 1 == 0 end,
	getSize = fixedSize(1),
	pack = function(b, c, v) buffer.writei8(b, c, v); return c + 1 end,
	unpack = function(b, c) return buffer.readi8(b, c), c + 1 end,
}

t.uint16 = {
	name = "uint16",
	_def = "uint16",
	validate = function(v) return type(v) == "number" and v >= 0 and v <= 65535 and v % 1 == 0 end,
	getSize = fixedSize(2),
	pack = function(b, c, v) buffer.writeu16(b, c, v); return c + 2 end,
	unpack = function(b, c) return buffer.readu16(b, c), c + 2 end,
}

t.uint32 = {
	name = "uint32",
	_def = "uint32",
	validate = function(v) return type(v) == "number" and v >= 0 and v <= 4294967295 and v % 1 == 0 end,
	getSize = fixedSize(4),
	pack = function(b, c, v) buffer.writeu32(b, c, v); return c + 4 end,
	unpack = function(b, c) return buffer.readu32(b, c), c + 4 end,
}

t.f32 = {
	name = "f32",
	_def = "f32",
	validate = function(v) return type(v) == "number" end,
	getSize = fixedSize(4),
	pack = function(b, c, v) buffer.writef32(b, c, v); return c + 4 end,
	unpack = function(b, c) return buffer.readf32(b, c), c + 4 end,
}

-- ============================================================================
-- ROBLOX TYPES
-- ============================================================================

t.Vector3 = {
	name = "Vector3",
	_def = "Vector3",
	validate = function(v) return typeof(v) == "Vector3" end,
	getSize = fixedSize(12), -- 3x f32
	pack = function(b, c, v)
		buffer.writef32(b, c, v.X)
		buffer.writef32(b, c + 4, v.Y)
		buffer.writef32(b, c + 8, v.Z)
		return c + 12
	end,
	unpack = function(b, c)
		return Vector3.new(
			buffer.readf32(b, c),
			buffer.readf32(b, c + 4),
			buffer.readf32(b, c + 8)
		), c + 12
	end,
}

t.Vector2 = {
	name = "Vector2",
	_def = "Vector2",
	validate = function(v) return typeof(v) == "Vector2" end,
	getSize = fixedSize(8), -- 2x f32
	pack = function(b, c, v)
		buffer.writef32(b, c, v.X)
		buffer.writef32(b, c + 4, v.Y)
		return c + 8
	end,
	unpack = function(b, c)
		return Vector2.new(
			buffer.readf32(b, c),
			buffer.readf32(b, c + 4)
		), c + 8
	end,
}

t.Color3 = {
	name = "Color3",
	_def = "Color3",
	validate = function(v) return typeof(v) == "Color3" end,
	getSize = fixedSize(3), -- 3x u8
	pack = function(b, c, v)
		buffer.writeu8(b, c, math.round(v.R * 255))
		buffer.writeu8(b, c + 1, math.round(v.G * 255))
		buffer.writeu8(b, c + 2, math.round(v.B * 255))
		return c + 3
	end,
	unpack = function(b, c)
		return Color3.fromRGB(
			buffer.readu8(b, c),
			buffer.readu8(b, c + 1),
			buffer.readu8(b, c + 2)
		), c + 3
	end,
}

t.CFrame = {
	name = "CFrame",
	_def = "CFrame",
	validate = function(v) return typeof(v) == "CFrame" end,
	getSize = fixedSize(24), -- Pos(12) + EulerAngles(12)
	pack = function(b, c, v)
		buffer.writef32(b, c, v.X)
		buffer.writef32(b, c + 4, v.Y)
		buffer.writef32(b, c + 8, v.Z)
		local rx, ry, rz = v:ToEulerAnglesYXZ()
		buffer.writef32(b, c + 12, rx)
		buffer.writef32(b, c + 16, ry)
		buffer.writef32(b, c + 20, rz)
		return c + 24
	end,
	unpack = function(b, c)
		local cframe = CFrame.new(
			buffer.readf32(b, c),
			buffer.readf32(b, c + 4),
			buffer.readf32(b, c + 8)
		) * CFrame.fromEulerAnglesYXZ(
			buffer.readf32(b, c + 12),
			buffer.readf32(b, c + 16),
			buffer.readf32(b, c + 20)
		)
		return cframe, c + 24
	end,
}

-- ============================================================================
-- INSTANCE REFERENCE ARRAYS
-- ============================================================================

t.instance = {
	name = "instance",
	_def = "instance",
	validate = function(v) return typeof(v) == "Instance" end,
	getSize = fixedSize(2), -- u16 Side channel index pointer (points to inst_array)
	pack = function(b, c, v, inst_array)
		table.insert(inst_array, v)
		buffer.writeu16(b, c, #inst_array)
		return c + 2
	end,
	unpack = function(b, c, inst_array)
		local index = buffer.readu16(b, c)
		return inst_array[index], c + 2
	end,
}

--[=[
	Create a schema that validates and packs an Instance of a specific class.

	@param className string -- Roblox class name accepted by `Instance:IsA`
	@return any -- instance schema
]=]
function t.instanceOf(className: string)
	return {
		name = "instance",
		_def = { type = "instanceOf", className = className },
		validate = function(v) return typeof(v) == "Instance" and v:IsA(className) end,
		getSize = fixedSize(2),
		pack = t.instance.pack,
		unpack = t.instance.unpack,
	}
end

-- ============================================================================
-- STRUCTURE COMPOSERS
-- ============================================================================

--[=[
	Create a schema that accepts `nil` or a value matching the inner schema.

	@param schema any -- schema used when a value is present
	@return any -- optional schema
]=]
function t.optional(schema)
	return {
		name = schema.name and ("optional_" .. schema.name) or "optional",
		_def = { type = "optional", inner = schema._def },
		validate = function(v)
			if v == nil then return true end
			return schema.validate(v)
		end,
		getSize = function(v)
			if v == nil then return 1 end -- 1 byte flag marking "nil"
			return 1 + schema.getSize(v) -- Flag marking "present" + size
		end,
		pack = function(b, c, v, inst_array)
			if v == nil then
				buffer.writeu8(b, c, 0)
				return c + 1
			else
				buffer.writeu8(b, c, 1)
				return schema.pack(b, c + 1, v, inst_array)
			end
		end,
		unpack = function(b, c, inst_array)
			local present = buffer.readu8(b, c)
			if present == 0 then
				return nil, c + 1
			else
				return schema.unpack(b, c + 1, inst_array)
			end
		end,
	}
end

--[=[
	Create an array schema with homogeneous element values.

	@param elementSchema any -- schema used for each array item
	@return any -- array schema
]=]
function t.array(elementSchema)
	return {
		name = elementSchema.name and ("array_" .. elementSchema.name) or "array",
		_def = { type = "array", inner = elementSchema._def },
		validate = function(v)
			if type(v) ~= "table" or #v > 65535 then return false end
			for i, val in ipairs(v) do
				if not elementSchema.validate(val) then return false end
			end
			return true
		end,
		getSize = function(v)
			local total = 2 -- u16 length
			if type(v) == "table" then
				for i, val in ipairs(v) do
					total += elementSchema.getSize(val)
				end
			end
			return total
		end,
		pack = function(b, c, v, inst_array)
			local len = type(v) == "table" and #v or 0
			buffer.writeu16(b, c, len)
			c += 2
			if len > 0 then
				for i = 1, len do
					c = elementSchema.pack(b, c, v[i], inst_array)
				end
			end
			return c
		end,
		unpack = function(b, c, inst_array)
			local len = buffer.readu16(b, c)
			c += 2
			local result = table.create(len)
			for i = 1, len do
				local val, nextCur = elementSchema.unpack(b, c, inst_array)
				result[i] = val
				c = nextCur
			end
			return result, c
		end,
	}
end

--[=[
	Create a deterministic struct schema from named fields.

	@param template { [string]: any } -- field schemas keyed by field name
	@return any -- struct schema
]=]
function t.struct(template)
	-- Pre-sort keys so serialization is deterministic
	local keys = {}
	local defTemplate = {}
	for key in pairs(template) do
		table.insert(keys, key)
		defTemplate[key] = template[key]._def
	end
	table.sort(keys)

	return {
		name = "struct",
		_def = { type = "struct", template = defTemplate },
		validate = function(v)
			if type(v) ~= "table" then return false end
			for _, key in ipairs(keys) do
				local schema = template[key]
				if not schema.validate(v[key]) then return false end
			end
			return true
		end,
		getSize = function(v)
			local total = 0
			if type(v) == "table" then
				for _, key in ipairs(keys) do
					total += template[key].getSize(v[key])
				end
			end
			return total
		end,
		pack = function(b, c, v, inst_array)
			if type(v) == "table" then
				for _, key in ipairs(keys) do
					c = template[key].pack(b, c, v[key], inst_array)
				end
			end
			return c
		end,
		unpack = function(b, c, inst_array)
			local result = {}
			for _, key in ipairs(keys) do
				local val, nextCur = template[key].unpack(b, c, inst_array)
				result[key] = val
				c = nextCur
			end
			return result, c
		end,
	}
end

--[=[
	Create a map schema with homogeneous key and value schemas.

	@param keySchema any -- schema used for each key
	@param valSchema any -- schema used for each value
	@return any -- map schema
]=]
function t.map(keySchema, valSchema)
	return {
		name = "map",
		_def = { type = "map", key = keySchema._def, val = valSchema._def },
		validate = function(v)
			if type(v) ~= "table" then return false end
			local count = 0
			for k, val in pairs(v) do
				count += 1
				if count > 65535 then return false end
				if not keySchema.validate(k) or not valSchema.validate(val) then return false end
			end
			return true
		end,
		getSize = function(v)
			local total = 2 -- u16 entries length
			if type(v) == "table" then
				for k, val in pairs(v) do
					total += keySchema.getSize(k)
					total += valSchema.getSize(val)
				end
			end
			return total
		end,
		pack = function(b, c, v, inst_array)
			local count = 0
			if type(v) == "table" then
				for _ in pairs(v) do count += 1 end
			end
			buffer.writeu16(b, c, count)
			c += 2
			
			if type(v) == "table" then
				for key, val in pairs(v) do
					c = keySchema.pack(b, c, key, inst_array)
					c = valSchema.pack(b, c, val, inst_array)
				end
			end
			return c
		end,
		unpack = function(b, c, inst_array)
			local count = buffer.readu16(b, c)
			c += 2
			local result = {}
			for _ = 1, count do
				local key, nextCur = keySchema.unpack(b, c, inst_array)
				c = nextCur
				local val, nextCur2 = valSchema.unpack(b, c, inst_array)
				c = nextCur2
				result[key] = val
			end
			return result, c
		end,
	}
end

-- ============================================================================
-- ADVANCED OPTIMIZATIONS (1-Byte Player Registries, Quantization)
-- ============================================================================

local RunService = game:GetService("RunService")
local IS_SERVER = RunService:IsServer()

-- Maximum number of free IDs to keep in the pool before compacting
local MAX_FREE_IDS = 256

local PlayerRegistry = {
	_idToPlayer = {},
	_freeIds = {},
	_nextId = 0
}

if IS_SERVER then
--[=[
	Assigns or returns a compact numeric id for a Player.
	@param player player: Player
	@return number
]=]
	function PlayerRegistry.assignId(player: Player)
		local id = table.remove(PlayerRegistry._freeIds) or PlayerRegistry._nextId
		if not PlayerRegistry._freeIds[1] then PlayerRegistry._nextId += 1 end
		PlayerRegistry._idToPlayer[id] = player
		player:SetAttribute("_RegistryID", id)
		return id
	end
	
	game:GetService("Players").PlayerAdded:Connect(PlayerRegistry.assignId)
	for _, p in game:GetService("Players"):GetPlayers() do PlayerRegistry.assignId(p) end
	
	game:GetService("Players").PlayerRemoving:Connect(function(player)
		local id = player:GetAttribute("_RegistryID")
		if id then
			PlayerRegistry._idToPlayer[id] = nil
			-- Only keep up to MAX_FREE_IDS to prevent unbounded memory growth
			if #PlayerRegistry._freeIds < MAX_FREE_IDS then
				table.insert(PlayerRegistry._freeIds, id)
			end
			-- If we exceed the limit, we simply don't recycle this ID
			-- The ID space is large enough (65535) that this is acceptable
		end
	end)
end

--[=[
	Returns the Player associated with a compact numeric id.
	@param id id: number
	@return Player?
]=]
function PlayerRegistry.getPlayer(id: number): Player?
	if IS_SERVER then return PlayerRegistry._idToPlayer[id] end
	for _, player in game:GetService("Players"):GetPlayers() do
		if player:GetAttribute("_RegistryID") == id then return player end
	end
	return nil
end

t.player = {
	name = "player",
	_def = "player",
	validate = function(v) return typeof(v) == "Instance" and v:IsA("Player") end,
	getSize = fixedSize(2),
	pack = function(b, c, v)
		local id = v:GetAttribute("_RegistryID")
		if not id and IS_SERVER then id = PlayerRegistry.assignId(v) end
		buffer.writeu16(b, c, id or 0)
		return c + 2
	end,
	unpack = function(b, c)
		local id = buffer.readu16(b, c)
		return PlayerRegistry.getPlayer(id), c + 2
	end,
}

-- ============================================================================
-- QUANTIZATION AND BITFIELDS
-- ============================================================================

-- Helper: calculate optimal primitive integer size based on bounds
local function getOptimalIntType(range: number, precision: number): (string, number)
	local maxValue = range / precision
	if maxValue <= 128 then return "int8", 1
	elseif maxValue <= 32768 then return "int16", 2
	else return "int32", 4
	end
end

--[=[
	Create a schema that packs named boolean flags into a single byte.

	@param flags { [string]: number } -- flag names mapped to bit indexes
	@return any -- bitfield schema
]=]
function t.bitfield(flags)
	return {
		name = "bitfield",
		_def = { type = "bitfield", flags = flags },
		validate = function(v) return type(v) == "table" end,
		getSize = fixedSize(1),
		pack = function(b, c, v)
			local bits = 0
			for flagName, bitIndex in pairs(flags) do
				if v[flagName] then
					bits = bit32.bor(bits, bit32.lshift(1, bitIndex))
				end
			end
			buffer.writeu8(b, c, bits)
			return c + 1
		end,
		unpack = function(b, c)
			local bits = buffer.readu8(b, c)
			local result = {}
			for flagName, bitIndex in pairs(flags) do
				result[flagName] = bit32.band(bits, bit32.lshift(1, bitIndex)) ~= 0
			end
			return result, c + 1
		end,
	}
end

--[=[
	Create a Vector3 schema that quantizes components according to precision
	and range, reducing payload size when possible.

	@param precision number -- world-unit precision step
	@param range number -- maximum absolute component range
	@return any -- quantized Vector3 schema
]=]
function t.quantized_vec3(precision: number, range: number)
	local intType, bytesComp = getOptimalIntType(range, precision)
	local size = bytesComp * 3

	return {
		name = "quantized_vec3",
		_def = { type = "quantized_vec3", precision = precision, range = range },
		validate = function(v) return typeof(v) == "Vector3" end,
		getSize = fixedSize(size),
		pack = function(b, c, v)
			local x = math.round(v.X / precision)
			local y = math.round(v.Y / precision)
			local z = math.round(v.Z / precision)
			if intType == "int8" then
				buffer.writei8(b, c, math.clamp(x, -128, 127))
				buffer.writei8(b, c + 1, math.clamp(y, -128, 127))
				buffer.writei8(b, c + 2, math.clamp(z, -128, 127))
			elseif intType == "int16" then
				buffer.writei16(b, c, math.clamp(x, -32768, 32767))
				buffer.writei16(b, c + 2, math.clamp(y, -32768, 32767))
				buffer.writei16(b, c + 4, math.clamp(z, -32768, 32767))
			else
				buffer.writei32(b, c, x)
				buffer.writei32(b, c + 4, y)
				buffer.writei32(b, c + 8, z)
			end
			return c + size
		end,
		unpack = function(b, c)
			local x, y, z
			if intType == "int8" then
				x = buffer.readi8(b, c) * precision
				y = buffer.readi8(b, c + 1) * precision
				z = buffer.readi8(b, c + 2) * precision
			elseif intType == "int16" then
				x = buffer.readi16(b, c) * precision
				y = buffer.readi16(b, c + 2) * precision
				z = buffer.readi16(b, c + 4) * precision
			else
				x = buffer.readi32(b, c) * precision
				y = buffer.readi32(b, c + 4) * precision
				z = buffer.readi32(b, c + 8) * precision
			end
			return Vector3.new(x, y, z), c + size
		end,
	}
end

-- ============================================================================
-- STRING INTERNING REGISTRY
-- ============================================================================
-- Reduces repeating string network overhead from [n bytes] -> 2 bytes by caching common strings into a registry.
-- 
-- WARNING: String interning is NOT automatically synchronized between server and client.
-- Both environments maintain separate registries. For cross-network usage, you MUST:
--   1. Pre-register all strings in the EXACT same order on both server and client, OR
--   2. Only use intern() for server-to-server or client-to-client communication, OR
--   3. Use t.string instead for client-server communication (safer but larger payload)
--
-- Example safe usage (pre-registration):
--   -- In a shared module loaded by both server and client:
--   local AnimationNames = { "Idle", "Walk", "Run", "Jump" }
--   for _, name in AnimationNames do t.intern("animations").register(name) end
--
local StringRegistry = { _registries = {} }

--[=[
	Returns the named string registry, creating it when needed.
	@param name name: string
	@return any
]=]
function StringRegistry.getRegistry(name: string)
	if not StringRegistry._registries[name] then
		StringRegistry._registries[name] = { idToStr = {}, strToId = {}, nId = 0 }
	end
	return StringRegistry._registries[name]
end

--[=[
	Returns the numeric id associated with a registered string.
	@param name name: string
	@param str str: string
	@return number?
]=]
function StringRegistry.getId(name: string, str: string)
	local r = StringRegistry.getRegistry(name)
	if r.strToId[str] then return r.strToId[str] end
	local id = r.nId
	r.nId += 1
	r.idToStr[id] = str; r.strToId[str] = id
	return id
end

-- Pre-register a string to ensure deterministic ID assignment
--[=[
	Registers a string in a named registry and returns its numeric id.
	@param name name: string
	@param str str: string
	@return number
]=]
function StringRegistry.register(name: string, str: string)
	StringRegistry.getId(name, str)
end

--[=[
	Create a schema that packs strings by registry id. Registries are local to
	the runtime, so cross-network usage requires deterministic pre-registration
	on both server and client.

	@param registryName string -- name of the string registry
	@return any -- interned string schema with a `register(str)` helper
]=]
function t.intern(registryName: string)
	return {
		name = "intern",
		_def = { type = "intern", registry = registryName },
		validate = function(v) return type(v) == "string" end,
		getSize = fixedSize(2),
		pack = function(b, c, v)
			buffer.writeu16(b, c, StringRegistry.getId(registryName, v))
			return c + 2
		end,
		unpack = function(b, c)
			local id = buffer.readu16(b, c)
			local str = StringRegistry.getRegistry(registryName).idToStr[id]
			if str == nil then
				warn(`[t.intern] Unknown string ID {id} in registry '{registryName}'. Ensure strings are pre-registered on both server and client.`)
				return "", c + 2
			end
			return str, c + 2
		end,
		-- Helper to pre-register strings for deterministic cross-network usage
		register = function(str: string)
			StringRegistry.register(registryName, str)
		end,
	}
end

--[=[
	Serialize a schema definition into a transportable descriptor.

	@param schema any -- schema created by this module
	@return any -- descriptor usable with `t.load`, or nil for unknown schemas
]=]
function t.dump(schema: any): any
	if type(schema) == "table" and schema._def then
		return schema._def
	end
	return nil
end

--[=[
	Recreate a schema from a descriptor produced by `t.dump`.

	@param def any -- schema descriptor
	@return any -- recreated schema, or nil if unsupported
]=]
function t.load(def: any): any
	if type(def) == "string" then
		return t[def]
	elseif type(def) == "table" then
		if def.type == "optional" then
			return t.optional(t.load(def.inner))
		elseif def.type == "array" then
			return t.array(t.load(def.inner))
		elseif def.type == "struct" then
			local tpl = {}
			for k, v in pairs(def.template) do tpl[k] = t.load(v) end
			return t.struct(tpl)
		elseif def.type == "map" then
			return t.map(t.load(def.key), t.load(def.val))
		elseif def.type == "instanceOf" then
			return t.instanceOf(def.className)
		elseif def.type == "bitfield" then
			return t.bitfield(def.flags)
		elseif def.type == "quantized_vec3" then
			return t.quantized_vec3(def.precision, def.range)
		elseif def.type == "intern" then
			return t.intern(def.registry)
		end
	end
	return nil
end

return t
