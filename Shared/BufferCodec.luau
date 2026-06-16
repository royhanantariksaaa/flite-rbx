--[[
	Weave Framework
	BufferCodec.luau
	
	Responsible for taking a payload of arguments `...`, matching them to an array of 
	`t` schema validators defined in `config.args`, and dynamically allocating 
	a pure Luau buffer that spans the entire byte-size of the payload!
]]

local BufferCodec = {}

--[[
	Compresses an arbitrary list of arguments into a unified Buffer and Instance Array.
	Returns (buf, inst_array)
]]
function BufferCodec.serialize(schemas: {any}, ...: any): (buffer, {Instance})
	local args = table.pack(...)
	local totalSize = 0
	
	-- 1. Measure the exact byte payload needed.
	for i = 1, #schemas do
		local schema = schemas[i]
		local val = args[i]
		
		-- Safely measure size even if val is unexpectedly nil (to prevent crashes on bad client calls)
		local success, size = pcall(schema.getSize, val)
		if not success then size = 0 end
		totalSize += size
	end
	
	-- 2. Allocate the exact buffer size
	local buf = buffer.create(totalSize)
	local inst_array = {}
	local cursor = 0
	
	-- 3. Write each value securely into the buffer sequentially.
	for i = 1, #schemas do
		local schema = schemas[i]
		local val = args[i]
		
		-- Safely pack even if val is unexpectedly nil
		local success, newCursor = pcall(schema.pack, buf, cursor, val, inst_array)
		if success then
			cursor = newCursor
		end
	end
	
	return buf, inst_array
end

--[[
	Decompresses a unified Buffer + Instance Array back into a table of native Lua arguments.
	Returns an array of reconstructed arguments.
]]
function BufferCodec.deserialize(schemas: {any}, buf: buffer, inst_array: {Instance}): {any}
	local results = table.create(#schemas)
	local cursor = 0
	
	for i = 1, #schemas do
		local schema = schemas[i]
		local val, nextCursor = schema.unpack(buf, cursor, inst_array)
		
		results[i] = val
		cursor = nextCursor
	end
	
	results.n = #schemas
	return results
end

return BufferCodec
