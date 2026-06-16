local PermissionPolicy = {}

local function isPolicy(value: any): boolean
	return type(value) == "table" and value.__frameworkPermissionPolicy == true
end

local function wrapEvaluator(evaluator: (any) -> (boolean, string?))
	return {
		__frameworkPermissionPolicy = true,
		evaluate = evaluator,
	}
end

local function evaluatePolicy(policy: any, context: any): (boolean, string?)
	if isPolicy(policy) then
		return policy.evaluate(context)
	end

	if type(policy) == "function" then
		local ok, result, reason = pcall(policy, context)
		if not ok then
			return false, `permission function errored: {result}`
		end
		if result == false then
			return false, reason or "permission function denied"
		end
		return true, nil
	end

	if type(policy) == "boolean" then
		return policy, if policy then nil else "permission denied"
	end

	return false, `unsupported permission policy type: {type(policy)}`
end

function PermissionPolicy.evaluate(policy: any, context: any): (boolean, string?)
	return evaluatePolicy(policy, context)
end

function PermissionPolicy.allowAll()
	return wrapEvaluator(function()
		return true, nil
	end)
end

function PermissionPolicy.deny(reason: string?)
	return wrapEvaluator(function()
		return false, reason or "denied by policy"
	end)
end

function PermissionPolicy.team(teamNameOrId: string | number)
	return wrapEvaluator(function(context)
		local player = context.player
		if not player or not player.Team then
			return false, "player has no team"
		end
		if type(teamNameOrId) == "string" then
			return player.Team.Name == teamNameOrId, `team must be {teamNameOrId}`
		end
		return player.Team.TeamColor.Number == teamNameOrId, "team id mismatch"
	end)
end

function PermissionPolicy.groupRank(groupId: number, minimumRank: number)
	return wrapEvaluator(function(context)
		local player = context.player
		if not player or type(player.GetRankInGroup) ~= "function" then
			return false, "invalid player"
		end
		local ok, rank = pcall(player.GetRankInGroup, player, groupId)
		if not ok then
			return false, "failed to resolve group rank"
		end
		return rank >= minimumRank, `group rank must be >= {minimumRank}`
	end)
end

function PermissionPolicy.userIds(allowedUserIds: { number })
	local allowed = {}
	for _, id in ipairs(allowedUserIds) do
		allowed[id] = true
	end
	return wrapEvaluator(function(context)
		local player = context.player
		return player ~= nil and allowed[player.UserId] == true, "user id is not allowed"
	end)
end

function PermissionPolicy.custom(fn: (any) -> (boolean, string?))
	return wrapEvaluator(function(context)
		local ok, result, reason = pcall(fn, context)
		if not ok then
			return false, `custom permission errored: {result}`
		end
		return result ~= false, reason
	end)
end

function PermissionPolicy.any(...: any)
	local policies = table.pack(...)
	return wrapEvaluator(function(context)
		local reasons = {}
		for i = 1, policies.n do
			local ok, reason = evaluatePolicy(policies[i], context)
			if ok then
				return true, nil
			end
			table.insert(reasons, reason or "denied")
		end
		return false, table.concat(reasons, " | ")
	end)
end

function PermissionPolicy.all(...: any)
	local policies = table.pack(...)
	return wrapEvaluator(function(context)
		for i = 1, policies.n do
			local ok, reason = evaluatePolicy(policies[i], context)
			if not ok then
				return false, reason
			end
		end
		return true, nil
	end)
end

function PermissionPolicy.negate(policy: any)
	return wrapEvaluator(function(context)
		local ok = evaluatePolicy(policy, context)
		return not ok, "negated policy denied"
	end)
end

return PermissionPolicy
