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

function FrameworkError.new(code: string, message: string, details: any?): any
	return {
		__frameworkError = true,
		code = code,
		message = message,
		details = details,
	}
end

function FrameworkError.isError(value: any): boolean
	return type(value) == "table" and value.__frameworkError == true and type(value.code) == "string"
end

function FrameworkError.ensure(value: any, fallbackCode: string, fallbackMessage: string): any
	if FrameworkError.isError(value) then
		return value
	end
	return FrameworkError.new(fallbackCode, fallbackMessage, { raw = value })
end

return FrameworkError
