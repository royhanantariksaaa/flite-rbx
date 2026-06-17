--!optimize 2
--[=[
	@module LifecycleRegistration
	@within Flite

	Binds service lifecycle registration hooks onto the service setup context.
]=]

local LifecycleRegistration = {}

--[=[
	Installs lifecycle registration methods on a service builder context.
	@param context context: any
]=]
function LifecycleRegistration.bind(context: any)
	function context:onInit(callback: () -> ())
		self._onInit = callback
	end

	function context:beforeServerShutdown(callback: (string?) -> ())
		self._beforeServerShutdown = callback
	end

	function context:onStart(callback: () -> ())
		self._onStart = callback
	end

	function context:onPlayerAdded(callback: (Player) -> ())
		self._onPlayerAdded = callback
	end

	function context:onPlayerRemoving(callback: (Player) -> ())
		self._onPlayerRemoving = callback
	end

	function context:onPlayerSpawned(callback: (Player, Model) -> ())
		self._onPlayerSpawned = callback
	end

	function context:onPlayerDespawned(callback: (Player, Model) -> ())
		self._onPlayerDespawned = callback
	end

	function context:onHeartbeat(callback: (number) -> ())
		self._onHeartbeat = callback
	end

	function context:onHeartbeatFixed(fixedDeltaTime: number, callback: (number) -> ())
		self._onHeartbeat = {
			callback = callback,
			fixedDeltaTime = fixedDeltaTime,
		}
	end

	function context:onStop(callback: () -> ())
		self._onStop = callback
	end
end

return LifecycleRegistration
