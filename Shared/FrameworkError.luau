--!native
--!optimize 2
--[=[
	@module FrameworkError
	@within Flite

	Structured error helpers and canonical framework error codes.
]=]

local FrameworkError = {}

FrameworkError.Codes = {
	ValidationError = "ValidationError",
	PermissionDenied = "PermissionDenied",
	RateLimited = "RateLimited",
	RejectedByMiddleware = "RejectedByMiddleware",
	Timeout = "Timeout",
	Canceled = "Canceled",
	ServiceNotFound = "ServiceNotFound",
	MethodNotFound = "MethodNotFound",
	DomainNotFound = "DomainNotFound",
	ServerError = "ServerError",
}

--[=[
	Create a structured framework error object.

	@param code string -- canonical code from `FrameworkError.Codes`
	@param message string -- human-readable error message
	@param details any? -- optional payload with additional context
	@return any -- framework error table
]=]
function FrameworkError.new(code: string, message: string, details: any?): any
	return {
		__frameworkError = true,
		code = code,
		message = message,
		details = details,
	}
end

--[=[
	Check whether a value is a framework error object.

	@param value any -- value to inspect
	@return boolean -- true when the value has framework error shape
]=]
function FrameworkError.isError(value: any): boolean
	return type(value) == "table" and value.__frameworkError == true and type(value.code) == "string"
end

--[=[
	Normalize any value into a framework error object.

	@param value any -- existing error or raw failure value
	@param fallbackCode string -- code used when `value` is not already an error
	@param fallbackMessage string -- message used when wrapping a raw value
	@return any -- existing or newly wrapped framework error
]=]
function FrameworkError.ensure(value: any, fallbackCode: string, fallbackMessage: string): any
	if FrameworkError.isError(value) then
		return value
	end
	return FrameworkError.new(fallbackCode, fallbackMessage, { raw = value })
end

return FrameworkError
