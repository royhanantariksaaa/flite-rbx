--[=[
	@module PersistenceRegistration
	@within Flite

	Binds persistence helpers for mapping service state into DataStore sessions.
]=]

local PersistenceRegistration = {}

--[=[
	Installs persistence registration methods on a service builder context.
	@param context context: any
]=]
function PersistenceRegistration.bind(context: any)
	function context:usePersistent(store: any, fields: { string }?)
		local fieldList = fields or {}
		if #fieldList == 0 then
			for fieldName, stateObj in self._states do
				local isMapState = type(stateObj.setFilter) == "function"
				if isMapState then
					table.insert(fieldList, fieldName)
				end
			end
		end
		self._persistent = { store = store, fields = fieldList }
	end

	function context:onPlayerReady(callback: (any, Player, { [string]: any }) -> ())
		self._onPlayerReady = callback
	end

	function context:onPlayerSessionEnd(callback: (any, Player, { [string]: any }, string?) -> ())
		self._onPlayerSessionEnd = callback
	end
end

return PersistenceRegistration
