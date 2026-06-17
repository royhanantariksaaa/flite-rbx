--!native
--!optimize 2
--[=[
	@module DependencySorter
	@within Flite

	DependencySorter
	Reusable topological sorter for framework registries (services/controllers/domains).
]=]

local DependencySorter = {}

--[=[
	Sorts dependency-aware nodes so dependencies initialize before dependents.
	@param nodesByName nodesByName: any
	@param getDependencies Optional callback that returns dependency names for a node.
	@return { any }
]=]
function DependencySorter.sort(nodesByName: any, getDependencies: (any) -> { string }?, nodeKind: string?): { any }
	local sorted = {}
	local visited = {}
	local visiting = {}
	local kind = nodeKind or "item"

	local function visit(name: string)
		if visiting[name] then
			error(`[Framework] Cyclic dependency detected involving {kind} '{name}'`)
		end
		if visited[name] then
			return
		end

		visiting[name] = true
		local node = nodesByName[name]
		if not node then
			error(`[Framework] Missing dependency detected for {kind} '{name}'`)
		end
		if node then
			local dependencies = getDependencies(node)
			if dependencies then
				for _, dependencyName in dependencies do
					visit(dependencyName)
				end
			end
		end

		visiting[name] = nil
		visited[name] = true
		if node then
			table.insert(sorted, node)
		end
	end

	for name in nodesByName do
		visit(name)
	end

	return sorted
end

return DependencySorter
