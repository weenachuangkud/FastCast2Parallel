--[[
	FastCastEventsModule used by the parallel tests.

	It is required inside each worker Actor VM and forwards every event to a
	BindableEvent in ReplicatedStorage so the main thread can observe it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local signal = ReplicatedStorage:WaitForChild("FastCast2TestSignal") :: BindableEvent

local function forward(name: string)
	return function(...)
		signal:Fire(name, ...)
	end
end

return {
	CastFire = forward("CastFire"),
	Hit = forward("Hit"),
	Pierced = forward("Pierced"),
	LengthChanged = forward("LengthChanged"),
	CastTerminating = forward("CastTerminating"),
	CanPierce = function(cast)
		-- Tests opt into piercing explicitly so the default worker behavior
		-- remains non-piercing.
		return cast.UserData ~= nil and cast.UserData.PierceAll == true
	end,
	OnStep = function(cast, _deltaTime)
		-- Test-only hook used to prove OnStep runs before the worker's movement.
		local userData = cast.UserData
		if not userData
			or typeof(userData.OnStepVelocity) ~= "Vector3"
			or userData.OnStepApplied
		then
			return
		end

		userData.OnStepApplied = true
		local trajectory = cast.StateInfo.Trajectory
		trajectory.Origin = cast.CFrame.Position
		trajectory.InitialVelocity = userData.OnStepVelocity
		trajectory.Acceleration = Vector3.zero
		trajectory.StartTime = cast.StateInfo.TotalRuntime
	end,
}
