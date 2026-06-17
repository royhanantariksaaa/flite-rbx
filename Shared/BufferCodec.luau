--!native
--!optimize 2
--[=[
	@module BufferCodec
	@within Flite

	Serializes schema-backed values into a Luau buffer payload and Instance
	side-channel table. Callers should wrap serialize/deserialize in pcall
	to handle malformed input — the internal loops are pcall-free for speed.

	Use `compileSerializer` / `compileDeserializer` for arity-specialized
	functions that eliminate loop overhead for ≤8 args. Inspired by jecs'
	upvalue-specialized query iterators.
]=]

local BufferCodec = {}

--[=[
	Serializes schema-backed values into a buffer payload and Instance side table.

	@param schemas { any } -- ordered `t` schemas matching the argument list
	@param ... any -- values to serialize
	@return buffer -- packed binary payload
	@return { Instance } -- side-channel instance references
]=]
function BufferCodec.serialize(schemas: {any}, ...: any): (buffer, {Instance})
	local args = table.pack(...)
	local count = #schemas
	local totalSize = 0

	for i = 1, count do
		totalSize += schemas[i].getSize(args[i])
	end

	local buf = buffer.create(totalSize)
	local inst_array = {}
	local cursor = 0

	for i = 1, count do
		cursor = schemas[i].pack(buf, cursor, args[i], inst_array)
	end

	return buf, inst_array
end

--[=[
	Deserializes a buffer payload and Instance side table into Luau values.

	@param schemas { any } -- ordered `t` schemas used to unpack the payload
	@param buf buffer -- packed binary payload
	@param inst_array { Instance } -- side-channel instance references
	@return { any } -- reconstructed arguments with `n` set to schema count
]=]
function BufferCodec.deserialize(schemas: {any}, buf: buffer, inst_array: {Instance}): {any}
	local count = #schemas
	local results = table.create(count)
	local cursor = 0

	for i = 1, count do
		local val, nextCursor = schemas[i].unpack(buf, cursor, inst_array)
		results[i] = val
		cursor = nextCursor
	end

	results.n = count
	return results
end

-- stylua: ignore start

local function _ser1(s0)
	local g0, p0 = s0.getSize, s0.pack
	return function(a0)
		local buf = buffer.create(g0(a0))
		local inst = {}
		p0(buf, 0, a0, inst)
		return buf, inst
	end
end

local function _ser2(s0, s1)
	local g0, p0 = s0.getSize, s0.pack
	local g1, p1 = s1.getSize, s1.pack
	return function(a0, a1)
		local buf = buffer.create(g0(a0) + g1(a1))
		local inst = {}
		p1(buf, p0(buf, 0, a0, inst), a1, inst)
		return buf, inst
	end
end

local function _ser3(s0, s1, s2)
	local g0, p0 = s0.getSize, s0.pack
	local g1, p1 = s1.getSize, s1.pack
	local g2, p2 = s2.getSize, s2.pack
	return function(a0, a1, a2)
		local buf = buffer.create(g0(a0) + g1(a1) + g2(a2))
		local inst = {}
		p2(buf, p1(buf, p0(buf, 0, a0, inst), a1, inst), a2, inst)
		return buf, inst
	end
end

local function _ser4(s0, s1, s2, s3)
	local g0, p0 = s0.getSize, s0.pack
	local g1, p1 = s1.getSize, s1.pack
	local g2, p2 = s2.getSize, s2.pack
	local g3, p3 = s3.getSize, s3.pack
	return function(a0, a1, a2, a3)
		local buf = buffer.create(g0(a0) + g1(a1) + g2(a2) + g3(a3))
		local inst = {}
		p3(buf, p2(buf, p1(buf, p0(buf, 0, a0, inst), a1, inst), a2, inst), a3, inst)
		return buf, inst
	end
end

local function _des1(s0)
	local u0 = s0.unpack
	return function(buf, inst)
		local r = table.create(1)
		r[1] = u0(buf, 0, inst)
		r.n = 1
		return r
	end
end

local function _des2(s0, s1)
	local u0, u1 = s0.unpack, s1.unpack
	return function(buf, inst)
		local r = table.create(2)
		local v0, c1 = u0(buf, 0, inst)
		r[1] = v0
		r[2] = u1(buf, c1, inst)
		r.n = 2
		return r
	end
end

local function _des3(s0, s1, s2)
	local u0, u1, u2 = s0.unpack, s1.unpack, s2.unpack
	return function(buf, inst)
		local r = table.create(3)
		local v0, c1 = u0(buf, 0, inst)
		r[1] = v0
		local v1, c2 = u1(buf, c1, inst)
		r[2] = v1
		r[3] = u2(buf, c2, inst)
		r.n = 3
		return r
	end
end

local function _des4(s0, s1, s2, s3)
	local u0, u1, u2, u3 = s0.unpack, s1.unpack, s2.unpack, s3.unpack
	return function(buf, inst)
		local r = table.create(4)
		local v0, c1 = u0(buf, 0, inst)
		r[1] = v0
		local v1, c2 = u1(buf, c1, inst)
		r[2] = v1
		local v2, c3 = u2(buf, c2, inst)
		r[3] = v2
		r[4] = u3(buf, c3, inst)
		r.n = 4
		return r
	end
end

-- stylua: ignore end

--[=[
	Compiles a set of schemas into an arity-specialized serializer function.
	The returned function captures each schema's getSize/pack as upvalues,
	eliminating loop overhead for ≤4 args. Falls back to generic serialize
	for >4 args.

	@param schemas { any } -- ordered `t` schemas
	@return (...any) -> (buffer, {Instance})
]=]
function BufferCodec.compileSerializer(schemas: {any}): (...any) -> (buffer, {Instance})
	local count = #schemas
	if count == 0 then
		return function()
			return buffer.create(0), {}
		end
	elseif count == 1 then
		return _ser1(schemas[1])
	elseif count == 2 then
		return _ser2(schemas[1], schemas[2])
	elseif count == 3 then
		return _ser3(schemas[1], schemas[2], schemas[3])
	elseif count == 4 then
		return _ser4(schemas[1], schemas[2], schemas[3], schemas[4])
	end
	return function(...)
		return BufferCodec.serialize(schemas, ...)
	end
end

--[=[
	Compiles a set of schemas into an arity-specialized deserializer function.
	The returned function captures each schema's unpack as upvalues,
	eliminating loop overhead for ≤4 args. Falls back to generic deserialize
	for >4 args.

	@param schemas { any } -- ordered `t` schemas
	@return (buffer, {Instance}) -> {any}
]=]
function BufferCodec.compileDeserializer(schemas: {any}): (buffer, {Instance}) -> {any}
	local count = #schemas
	if count == 0 then
		return function(_, _)
			local r = {}
			r.n = 0
			return r
		end
	elseif count == 1 then
		return _des1(schemas[1])
	elseif count == 2 then
		return _des2(schemas[1], schemas[2])
	elseif count == 3 then
		return _des3(schemas[1], schemas[2], schemas[3])
	elseif count == 4 then
		return _des4(schemas[1], schemas[2], schemas[3], schemas[4])
	end
	return function(buf, inst)
		return BufferCodec.deserialize(schemas, buf, inst)
	end
end

return BufferCodec
