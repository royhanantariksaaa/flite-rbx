--!native
--!optimize 2
--[=[
	@module BufferCodec
	@within Flite

	Serializes schema-backed values into a Luau buffer payload and Instance
	side-channel table. Callers should wrap serialize/deserialize in pcall
	to handle malformed input — the internal loops are pcall-free for speed.
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

return BufferCodec
