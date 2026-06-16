local HttpService = game:GetService("HttpService")

local CancelToken = {}
CancelToken.__index = CancelToken

function CancelToken.new()
	local self = setmetatable({}, CancelToken)
	self.id = HttpService:GenerateGUID(false)
	self._cancelled = false
	self._reason = nil
	self._listeners = {}
	return self
end

function CancelToken:isCancelled(): boolean
	return self._cancelled
end

function CancelToken:getReason()
	return self._reason
end

function CancelToken:onCancel(callback: (any?) -> ())
	if self._cancelled then
		callback(self._reason)
		return function() end
	end

	table.insert(self._listeners, callback)
	local index = #self._listeners
	return function()
		if self._listeners[index] == callback then
			self._listeners[index] = false
		end
	end
end

function CancelToken:cancel(reason: any?)
	if self._cancelled then
		return
	end

	self._cancelled = true
	self._reason = reason

	for _, listener in ipairs(self._listeners) do
		if type(listener) == "function" then
			listener(reason)
		end
	end
	table.clear(self._listeners)
end

return CancelToken
