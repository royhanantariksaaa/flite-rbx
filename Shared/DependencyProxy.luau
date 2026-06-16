--[[
	DependencyProxy
	Creates a lazy proxy that resolves a dependency on first access and
	auto-binds function calls to the resolved dependency table.
]]

local DependencyProxy = {}

function DependencyProxy.create(dependencyName: string, resolveFn: (string) -> any, notFoundMessage: string)
	local proxy = {}
	local resolved = nil

	setmetatable(proxy, {
		__index = function(_, key)
			if not resolved then
				resolved = resolveFn(dependencyName)
			end
			if not resolved then
				error(notFoundMessage)
			end

			local value = resolved[key]
			if type(value) == "function" then
				return function(_, ...)
					return value(resolved, ...)
				end
			end
			return value
		end,
	})

	return proxy
end

return DependencyProxy
