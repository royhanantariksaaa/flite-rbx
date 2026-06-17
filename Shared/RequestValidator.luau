--[=[
	@module RequestValidator
	@within Flite

	RequestValidator
	Validates incoming client requests against exposing configurations.
	Handles rate limiting, type checking/schema validation, and middleware execution.
]=]

local RequestValidator = {}
local FrameworkError = require(script.Parent.FrameworkError)
local PermissionPolicy = require(script.Parent.PermissionPolicy)

local rateLimits = {}

-- Auto-cleanup for rate limits
game:GetService("Players").PlayerRemoving:Connect(function(player)
	rateLimits[player] = nil
end)

local function ensurePlayerRateLimitBucket(player: Player)
	local playerBucket = rateLimits[player]
	if not playerBucket then
		playerBucket = {}
		rateLimits[player] = playerBucket
	end
	return playerBucket
end

local function checkRateLimit(player: Player, key: string, interval: number, onSpam: ((Player) -> ())?): boolean
	local t = os.clock()
	local pLimits = ensurePlayerRateLimitBucket(player)
	local last = pLimits[key]
	if last ~= nil and t - last < interval then
		if type(onSpam) == "function" then
			onSpam(player)
		end
		return false
	end
	pLimits[key] = t
	return true
end

local function validateValue(argValidator: any, val: any, label: string): (boolean, string?)
	if type(argValidator) == "table" and type(argValidator.validate) == "function" then
		local success = argValidator.validate(val)
		if not success then
			return false, `failed schema '{argValidator.name or "unknown"}'`
		end
		return true, nil
	end

	if type(argValidator) == "function" then
		local success, errMsg = argValidator(val)
		if not success then
			return false, errMsg or "Invalid format"
		end
		return true, nil
	end

	if type(argValidator) == "string" then
		local actualType = typeof(val)
		local optionalType = string.sub(argValidator, -1) == "?"
		local expectedType = optionalType and string.sub(argValidator, 1, -2) or argValidator
		if val == nil then
			if optionalType then
				return true, nil
			end
			return false, `expected {argValidator}, got nil`
		end
		if actualType ~= expectedType then
			return false, `expected {argValidator}, got {actualType}`
		end
		return true, nil
	end

	return false, `invalid validator type for {label}`
end

local function runLegacyMiddleware(middlewareFn: any, player: Player, entryName: string, args: any): (boolean, string?)
	local success, result = pcall(middlewareFn, player, entryName, table.unpack(args, 1, args.n))
	if not success then
		return false, tostring(result)
	end
	if result == false then
		return false, "rejected by legacy middleware"
	end
	return true, nil
end

local function runMiddlewarePreset(entry: string, ctx: any): boolean
	if entry == "auth.required" then
		return ctx.player ~= nil and ctx.player.Parent ~= nil
	end

	if entry == "trace" then
		ctx.traceId = `{ctx.serviceName}:{ctx.entryName}:{math.floor(os.clock() * 1000)}`
		return true
	end

	local limitCount, limitWindow = string.match(entry, "^rateLimit%(([%d%.]+),([%d%.]+)%)$")
	if limitCount and limitWindow then
		local interval = tonumber(limitWindow)
		local perCount = tonumber(limitCount)
		if interval and perCount and perCount > 0 then
			return checkRateLimit(
				ctx.player,
				`preset::{ctx.serviceName}_{ctx.entryName}`,
				interval / perCount,
				nil
			)
		end
	end

	return true
end

local function runMiddlewareChain(service: any, config: any, ctx: any, args: any): (boolean, string?)
	local middlewareList = {}

	if service and type(service._middlewares) == "table" then
		for _, middlewareFn in ipairs(service._middlewares) do
			table.insert(middlewareList, middlewareFn)
		end
	end
	if type(config.middleware) == "table" then
		for _, middlewareFn in ipairs(config.middleware) do
			table.insert(middlewareList, middlewareFn)
		end
	elseif type(config.middleware) == "function" then
		table.insert(middlewareList, config.middleware)
	end

	for _, middlewareEntry in ipairs(middlewareList) do
		if type(middlewareEntry) == "string" then
			if not runMiddlewarePreset(middlewareEntry, ctx) then
				return false, "rejected by middleware preset"
			end
		elseif type(middlewareEntry) == "function" then
			local nextCalled = false
			local function nextFn()
				nextCalled = true
				return true
			end

			local success, result = pcall(middlewareEntry, ctx, nextFn)
			if success then
				if result == false then
					return false, "rejected by middleware"
				end
				if not nextCalled and result == nil then
					-- Treat omitted return in context middleware as allow.
				end
			else
				-- Backward-compat fallback: legacy middleware signature (player, methodName, ...args)
				local legacyOk, legacyReason = runLegacyMiddleware(middlewareEntry, ctx.player, ctx.entryName, args)
				if not legacyOk then
					return false, legacyReason or "rejected by legacy middleware"
				end
			end
		else
			return false, `unsupported middleware entry type: {type(middlewareEntry)}`
		end
	end

	return true, nil
end

local function getValidationArgs(config: any): any
	if type(config) ~= "table" then
		return nil
	end
	if type(config.args) == "table" then
		return config.args
	end
	if type(config.contract) == "table" and type(config.contract.args) == "table" then
		return config.contract.args
	end
	if config.__frameworkContract == true and type(config.args) == "table" then
		return config.args
	end
	return nil
end

local function getValidationReturns(config: any): any
	if type(config) ~= "table" then
		return nil
	end
	if type(config.returns) == "table" then
		return config.returns
	end
	if type(config.contract) == "table" and type(config.contract.returns) == "table" then
		return config.contract.returns
	end
	if config.__frameworkContract == true and type(config.returns) == "table" then
		return config.returns
	end
	return nil
end

--[=[
	Validates a client request.
	@param player The player making the request.
	@param serviceName The name of the service or domain.
	@param service The actual service/domain instance (for service-level middlewares).
	@param entryName The name of the method or signal.
	@param config The exposed configuration block.
	@param metadata Optional framework metadata passed with the request.
	@param requestContext Optional cancellation/timeout context.
	@param ... The arguments passed by the client.
	@return boolean
	@return any?
]=]
function RequestValidator.validate(
	player: Player,
	serviceName: string,
	service: any,
	entryName: string,
	config: any,
	metadata: any?,
	requestContext: any?,
	...: any
): (boolean, any?)
	local safeConfig = if type(config) == "table" then config else {}
	local args = table.pack(...)
	local effectiveMetadata = metadata
	if metadata ~= nil and (type(metadata) ~= "table" or metadata.__frameworkMeta ~= true) then
		local shifted = table.pack(metadata, table.unpack(args, 1, args.n))
		args = shifted
		effectiveMetadata = nil
	end

	if requestContext and type(requestContext.assertActive) == "function" then
		local activeOk, activeErr = requestContext:assertActive()
		if not activeOk then
			return false, activeErr
		end
	end

	-- 1. Rate Limiting
	if safeConfig.rateLimit then
		local key = serviceName .. "_" .. entryName
		if not checkRateLimit(player, key, safeConfig.rateLimit, safeConfig.onSpam) then
			return false, FrameworkError.new(
				FrameworkError.Codes.RateLimited,
				`{serviceName}.{entryName} is rate limited`
			)
		end
	end

	if safeConfig.allow ~= nil then
		local allowed, reason = PermissionPolicy.evaluate(safeConfig.allow, {
			player = player,
			service = service,
			serviceName = serviceName,
			entryName = entryName,
			config = safeConfig,
			metadata = effectiveMetadata,
			requestContext = requestContext,
		})
		if not allowed then
			return false, FrameworkError.new(
				FrameworkError.Codes.PermissionDenied,
				reason or `Permission denied for {serviceName}.{entryName}`
			)
		end
	end

	-- 2. Argument Validation (Knit-style, primitive strings, or t schemas)
	local argValidators = getValidationArgs(safeConfig)
	if argValidators then
		for i, argValidator in argValidators do
			local val = args[i]
			local ok, err = validateValue(argValidator, val, `arg {i}`)
			if not ok then
				return false, FrameworkError.new(
					FrameworkError.Codes.ValidationError,
					`arg {i} of {serviceName}.{entryName} {err}`
				)
			end
		end
	end

	-- 3. Middleware chain (v2 + backward compatibility)
	local ctx = {
		player = player,
		service = service,
		serviceName = serviceName,
		entryName = entryName,
		args = args,
		config = safeConfig,
		metadata = effectiveMetadata,
	}
	local middlewareOk, middlewareReason = runMiddlewareChain(service, safeConfig, ctx, args)
	if not middlewareOk then
		return false, FrameworkError.new(
			FrameworkError.Codes.RejectedByMiddleware,
			middlewareReason or `request to {serviceName}.{entryName} rejected by middleware`
		)
	end

	return true, nil
end

--[=[
	Validates method return values against configured return schemas.
	@param serviceName serviceName: string
	@param entryName entryName: string
	@param config config: any
]=]
function RequestValidator.validateReturns(serviceName: string, entryName: string, config: any, ...: any): boolean
	local returnValidators = getValidationReturns(config)
	if not returnValidators then
		return true
	end

	local values = table.pack(...)
	for i, validator in returnValidators do
		local ok, err = validateValue(validator, values[i], `return {i}`)
		if not ok then
			warn(`[Framework] Return validation failed: {serviceName}.{entryName} {err}`)
			return false
		end
	end

	return true
end

return RequestValidator
