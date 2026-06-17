--[=[
	@module CancelToken
	@within Flite

	Cooperative cancellation token for async framework operations.
]=]

local HttpService = game:GetService("HttpService")

local CancelToken = {}
CancelToken.__index = CancelToken

--[=[
	Create a new uncancelled token.

	@return CancelToken -- token passed to cancellable operations
]=]
function CancelToken.new()
	local self = setmetatable({}, CancelToken)
	self.id = HttpService:GenerateGUID(false)
	self._cancelled = false
	self._reason = nil
	self._listeners = {}
	return self
end

--[=[
	Check whether this token has been cancelled.

	@return boolean -- true after `:cancel()` has been called
]=]
function CancelToken:isCancelled(): boolean
	return self._cancelled
end

--[=[
	Get the reason passed to `:cancel()`, if any.

	@return any? -- cancellation reason
]=]
function CancelToken:getReason()
	return self._reason
end

--[=[
	Register a callback to run when the token is cancelled. If the token is
	already cancelled, the callback runs immediately.

	@param callback (any?) -> () -- receives the cancellation reason
	@return () -> () -- unsubscribe function
]=]
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

--[=[
	Cancel the token and notify all listeners once.

	@param reason any? -- optional cancellation reason
]=]
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
