--[[
	FastCast2 functional tests.

	These cover the checklist in TESTS.md: initialization, the three cast
	variants, every public event, ObjectCache, movement modes, cast
	manipulation, and the parallel-only extensions.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local FastCast = require(ReplicatedStorage:WaitForChild("FastCast2"))
local FastCastEnums = require(ReplicatedStorage.FastCast2:WaitForChild("FastCastEnums"))

local Framework = require(script.Parent.Framework)
local TestEventsModule = script.Parent:WaitForChild("TestEventsModule")

local CAST_TYPES = { "Raycast", "Blockcast", "Spherecast" }
local HIT_TIMEOUT = 5

local arenaCounter = 0

local function createArena(): Folder
	arenaCounter += 1
	local arena = Instance.new("Folder")
	arena.Name = "FastCast2TestArena" .. arenaCounter
	arena.Parent = workspace
	return arena
end

local function createWall(parent: Instance, position: Vector3, size: Vector3): Part
	local wall = Instance.new("Part")
	wall.Name = "Wall"
	wall.Anchored = true
	wall.CanCollide = true
	wall.CanQuery = true
	wall.Size = size
	wall.Position = position
	wall.Parent = parent
	return wall
end

local function createContainer(parent: Instance): Folder
	local container = Instance.new("Folder")
	container.Name = "Projectiles"
	container.Parent = parent
	return container
end

local function makeBehavior(container: Instance): any
	local behavior = FastCast.newBehavior()
	behavior.MaxDistance = 1e6
	behavior.Acceleration = Vector3.zero
	behavior.CosmeticBulletContainer = container

	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.IgnoreWater = true
	params.FilterDescendantsInstances = { container }
	behavior.RaycastParams = params

	return behavior
end

local function fire(caster: any, castType: string, origin: Vector3, direction: Vector3, velocity: number, behavior: any)
	if castType == "Blockcast" then
		caster:BlockcastFire(origin, Vector3.one, direction, velocity, behavior)
	elseif castType == "Spherecast" then
		caster:SpherecastFire(origin, 0.5, direction, velocity, behavior)
	else
		caster:RaycastFire(origin, direction, velocity, behavior)
	end
end

local function createParallelCaster(events: { [string]: any }?): any
	local caster = FastCast.new()

	for name, fn in events or {} do
		caster[name] = fn
	end

	return caster
end

local function registerParallelCastTypes(test: (string, any) -> ())
	for _, castType in CAST_TYPES do
		test(castType .. " reaches a wall", function(expect)
			local arena = createArena()
			local wall = createWall(arena, Vector3.new(0, 0, -40), Vector3.new(50, 50, 2))
			local container = createContainer(arena)
			local behavior = makeBehavior(container)

			local hitInstance = nil
			local terminated = false

			local caster = createParallelCaster({
				Hit = function(_, result)
					hitInstance = result.Instance
				end,
				CastTerminating = function()
					terminated = true
				end,
			})

			fire(caster, castType, Vector3.new(0, 0, 0), Vector3.new(0, 0, -1), 120, behavior)

			expect.truthy(
				Framework.waitFor(function()
					return hitInstance ~= nil
				end, HIT_TIMEOUT),
				castType .. " never registered a hit"
			)
			expect.equal(hitInstance, wall, castType .. " hit the wrong instance")
			expect.truthy(
				Framework.waitFor(function()
					return terminated
				end, HIT_TIMEOUT),
				castType .. " never terminated after the hit"
			)

			caster:Destroy()
			arena:Destroy()
		end)
	end
end

return function()
	return {
		Framework.describe("FastCastBehavior", function(test)
			test("newBehavior returns the documented defaults", function(expect)
				local behavior = FastCast.newBehavior()

				expect.equal(behavior.MaxDistance, 1000, "MaxDistance default changed")
				expect.near(behavior.Acceleration, Vector3.zero, 1e-6, "Acceleration default changed")
				expect.equal(
					behavior.HighFidelityBehavior,
					FastCastEnums.HighFidelityBehavior.Default,
					"HighFidelityBehavior default changed"
				)
				expect.equal(behavior.AutoIgnoreContainer, true, "AutoIgnoreContainer default changed")
			end)
		end),

		Framework.describe("FastCast", function(test)
			test("initializes shared runtime and creates casters", function(expect)
				FastCast.Init(2, "BulkMoveTo")
				local caster = createParallelCaster()
				expect.equal(type(caster.CasterId), "number", "caster did not receive a numeric ID")

				caster:Destroy()
			end)

			registerParallelCastTypes(test)

			test("multiple casters share runtime and route events by CasterId", function(expect)
				local casterAId = nil
				local casterBId = nil
				local casterA = createParallelCaster({
					CastFire = function(cast)
						casterAId = cast.CasterId
					end,
				})
				local casterB = createParallelCaster({
					CastFire = function(cast)
						casterBId = cast.CasterId
					end,
				})

				local behavior = FastCast.newBehavior()
				casterA:RaycastFire(Vector3.zero, Vector3.yAxis, 50, behavior)
				casterB:RaycastFire(Vector3.zero, Vector3.xAxis, 50, behavior)

				expect.truthy(Framework.waitFor(function()
					return casterAId ~= nil and casterBId ~= nil
				end, HIT_TIMEOUT), "CastFire events were not routed to both casters")
				expect.equal(casterAId, casterA.CasterId, "caster A received another caster's event")
				expect.equal(casterBId, casterB.CasterId, "caster B received another caster's event")
				expect.truthy(casterA.CasterId ~= casterB.CasterId, "casters shared the same numeric ID")

				casterA:Destroy()
				expect.truthy(Framework.waitFor(function()
					return casterA.CasterId == nil
				end, HIT_TIMEOUT), "destroying caster A did not finish")

				casterBId = nil
				casterB:RaycastFire(Vector3.zero, Vector3.zAxis, 50, behavior)
				expect.truthy(Framework.waitFor(function()
					return casterBId ~= nil
				end, HIT_TIMEOUT), "destroying caster A stopped the shared runtime")
				expect.equal(casterBId, casterB.CasterId, "caster B stopped receiving its own events")

				casterB:Destroy()
			end)

			test("movement mode can be switched", function(expect)
				local caster = createParallelCaster()
				caster:SetMovementModeEnabled(true, "Motor6D")
				expect.equal(caster.MovementMode, "Motor6D", "movement mode was not switched to Motor6D")

				caster:SetMovementModeEnabled(true, "BulkMoveTo")
				expect.equal(caster.MovementMode, "BulkMoveTo", "movement mode was not switched back")
				caster:Destroy()
			end)

			test("cast velocity, acceleration and position can be manipulated", function(expect)
				local arena = createArena()
				local container = createContainer(arena)
				local behavior = makeBehavior(container)
				local firedCast = nil

				local caster = createParallelCaster({
					CastFire = function(cast)
						firedCast = cast
					end,
				})

				fire(caster, "Raycast", Vector3.new(0, 0, 0), Vector3.new(0, 1, 0), 60, behavior)
				expect.truthy(Framework.waitFor(function()
					return firedCast ~= nil
				end, HIT_TIMEOUT), "parallel CastFire never ran")

				local cast = firedCast :: any
				FastCast:SetVelocityCast(cast, Vector3.new(0, 0, -100))
				FastCast:AddVelocityCast(cast, Vector3.new(10, 0, 0))
				FastCast:SetAccelerationCast(cast, Vector3.new(0, -10, 0))
				FastCast:AddAccelerationCast(cast, Vector3.new(0, -5, 0))
				FastCast:SetPositionCast(cast, Vector3.new(5, 5, 5))
				FastCast:AddPositionCast(cast, Vector3.new(1, 0, 0))
				caster:SyncChangesToCast(cast)

				expect.near(FastCast:GetVelocityCast(cast), Vector3.new(10, 0, -100), 1e-3, "velocity was not updated")
				expect.near(FastCast:GetAccelerationCast(cast), Vector3.new(0, -15, 0), 1e-3, "acceleration was not updated")
				expect.near(FastCast:GetPositionCast(cast), Vector3.new(6, 5, 5), 1e-3, "position was not updated")

				FastCast:SetVelocity(cast, Vector3.new(1, 2, 3))
				FastCast:SetAcceleration(cast, Vector3.new(4, 5, 6))
				caster:SyncChangesToCast(cast)
				expect.near(FastCast:GetVelocityCast(cast), Vector3.new(1, 2, 3), 1e-3, "SetVelocity alias did not update velocity")
				expect.near(FastCast:GetAccelerationCast(cast), Vector3.new(4, 5, 6), 1e-3, "SetAcceleration alias did not update acceleration")

				FastCast:TerminateCast(cast)
				caster:Destroy()
				arena:Destroy()
			end)

			test("trajectory sync preserves worker runtime, distance, and position", function(expect)
				local arena = createArena()
				local container = createContainer(arena)
				local behavior = makeBehavior(container)
				behavior.FastCastEventsConfig.UseLengthChanged = true

				local firedCast = nil
				local sampleCount = 0
				local workerRuntime = 0
				local workerDistance = 0
				local workerPosition = Vector3.zero

				local caster = createParallelCaster({
					CastFire = function(cast)
						firedCast = cast
					end,
					LengthChanged = function(cast)
						sampleCount += 1
						workerRuntime = cast.StateInfo.TotalRuntime
						workerDistance = cast.StateInfo.DistanceCovered
						workerPosition = cast.CFrame.Position
					end,
				})

				fire(caster, "Raycast", Vector3.zero, Vector3.yAxis, 60, behavior)
				expect.truthy(
					Framework.waitFor(function()
						return firedCast ~= nil and workerRuntime >= 0.15
					end, HIT_TIMEOUT),
					"cast did not advance far enough before synchronization"
				)

				local initialSampleCount = sampleCount
				local initialRuntime = workerRuntime
				local initialDistance = workerDistance
				local initialPosition = workerPosition

				-- Use the original CastFire snapshot deliberately; it is stale by now.
				FastCast:SetVelocity(firedCast, Vector3.new(0, 0, -60))
				caster:SyncChangesToCast(firedCast)

				expect.truthy(
					Framework.waitFor(function()
						return sampleCount > initialSampleCount
							and workerPosition.Z < initialPosition.Z - 0.1
					end, HIT_TIMEOUT),
					"worker did not apply the new velocity"
				)
				expect.truthy(workerRuntime >= initialRuntime, "trajectory sync rewound worker runtime")
				expect.truthy(workerDistance >= initialDistance, "trajectory sync rewound accumulated distance")
				expect.greaterThan(workerPosition.Y, 3, "trajectory sync reset the projectile to its stale origin")

				-- A later sync of unrelated cast data must not replay the old path.
				local runtimeBeforeUserDataSync = workerRuntime
				local distanceBeforeUserDataSync = workerDistance
				local sampleBeforeUserDataSync = sampleCount
				firedCast.UserData = { SyncMarker = true }
				caster:SyncChangesToCast(firedCast)

				expect.truthy(
					Framework.waitFor(function()
						return sampleCount > sampleBeforeUserDataSync
					end, HIT_TIMEOUT),
					"cast stopped updating after UserData synchronization"
				)
				expect.truthy(workerRuntime >= runtimeBeforeUserDataSync, "UserData sync rewound worker runtime")
				expect.truthy(workerDistance >= distanceBeforeUserDataSync, "UserData sync rewound accumulated distance")
				expect.greaterThan(workerPosition.Y, 3, "UserData sync reset the projectile position")

				FastCast:TerminateCast(firedCast)
				caster:Destroy()
				arena:Destroy()
			end)

			test("HighFidelity Always still resolves a hit", function(expect)
				local arena = createArena()
				local wall = createWall(arena, Vector3.new(0, 0, -40), Vector3.new(50, 50, 2))
				local container = createContainer(arena)
				local behavior = makeBehavior(container)
				behavior.HighFidelityBehavior = FastCastEnums.HighFidelityBehavior.Always
				behavior.HighFidelitySegmentSize = 1

				local hitInstance = nil
				local caster = createParallelCaster({
					Hit = function(_, result)
						hitInstance = result.Instance
					end,
				})

				fire(caster, "Raycast", Vector3.new(0, 0, 0), Vector3.new(0, 0, -1), 120, behavior)
				expect.truthy(Framework.waitFor(function()
					return hitInstance ~= nil
				end, HIT_TIMEOUT), "high-fidelity cast never hit the wall")
				expect.equal(hitInstance, wall, "high-fidelity cast hit the wrong instance")

				caster:Destroy()
				arena:Destroy()
			end)

			test("HighFidelity Always terminates when MaxDistance is reached", function(expect)
				local arena = createArena()
				local container = createContainer(arena)
				local behavior = makeBehavior(container)
				behavior.MaxDistance = 15
				behavior.HighFidelityBehavior = FastCastEnums.HighFidelityBehavior.Always
				behavior.HighFidelitySegmentSize = 1
				behavior.FastCastEventsConfig.UseCastTerminating = true

				local hitCount = 0
				local terminationCount = 0
				local caster = createParallelCaster({
					Hit = function()
						hitCount += 1
					end,
					CastTerminating = function()
						terminationCount += 1
					end,
				})

				fire(caster, "Raycast", Vector3.zero, Vector3.yAxis, 120, behavior)

				expect.truthy(
					Framework.waitFor(function()
						return terminationCount > 0
					end, HIT_TIMEOUT),
					"high-fidelity cast did not terminate at MaxDistance"
				)

				task.wait(0.1)
				expect.equal(hitCount, 0, "MaxDistance termination incorrectly reported a hit")
				expect.equal(terminationCount, 1, "MaxDistance termination fired more than once")

				caster:Destroy()
				arena:Destroy()
			end)

			test("MaxLifetime expires casts at a simulation update boundary", function(expect)
				local arena = createArena()
				local container = createContainer(arena)
				local behavior = makeBehavior(container)
				behavior.MaxLifetime = 0.1

				local terminatedRuntime = nil
				local caster = createParallelCaster({
					CastTerminating = function(cast)
						terminatedRuntime = cast.StateInfo.TotalRuntime
					end,
				})
				fire(caster, "Raycast", Vector3.zero, Vector3.yAxis, 10, behavior)

				expect.truthy(
					Framework.waitFor(function()
						return terminatedRuntime ~= nil
					end, HIT_TIMEOUT),
					"cast did not terminate after MaxLifetime"
				)
				expect.truthy(
					terminatedRuntime >= behavior.MaxLifetime,
					"cast terminated before reaching MaxLifetime"
				)

				caster:Destroy()
				arena:Destroy()
			end)

			test("MaxLifetime zero terminates before the first movement update", function(expect)
				local arena = createArena()
				local container = createContainer(arena)
				local behavior = makeBehavior(container)
				behavior.MaxLifetime = 0
				behavior.FastCastEventsConfig.UseLengthChanged = true

				local terminationCount = 0
				local lengthChangedCount = 0
				local caster = createParallelCaster({
					CastTerminating = function()
						terminationCount += 1
					end,
					LengthChanged = function()
						lengthChangedCount += 1
					end,
				})
				fire(caster, "Raycast", Vector3.zero, Vector3.yAxis, 120, behavior)

				expect.truthy(
					Framework.waitFor(function()
						return terminationCount > 0
					end, HIT_TIMEOUT),
					"zero-lifetime cast did not terminate"
				)
				task.wait(0.1)
				expect.equal(terminationCount, 1, "termination fired more than once")
				expect.equal(lengthChangedCount, 0, "zero-lifetime cast moved before termination")

				caster:Destroy()
				arena:Destroy()
			end)

			test("PauseCast and ResumeCast freeze and resume worker simulation", function(expect)
				local arena = createArena()
				local wall = createWall(arena, Vector3.new(0, 0, -20), Vector3.new(50, 50, 2))
				local container = createContainer(arena)
				local behavior = makeBehavior(container)
				local firedCast = nil
				local hitInstance = nil
				local terminationCount = 0

				local caster = createParallelCaster({
					CastFire = function(cast)
						firedCast = cast
						FastCast:PauseCast(cast)
					end,
					Hit = function(_, result)
						hitInstance = result.Instance
					end,
					CastTerminating = function()
						terminationCount += 1
					end,
				})

				fire(caster, "Raycast", Vector3.zero, Vector3.new(0, 0, -1), 120, behavior)
				expect.truthy(
					Framework.waitFor(function()
						return firedCast ~= nil
					end, HIT_TIMEOUT),
					"CastFire did not provide an active cast"
				)

				task.wait(0.25)
				expect.equal(hitInstance, nil, "paused cast continued to hit")
				expect.equal(terminationCount, 0, "paused cast terminated while paused")

				FastCast:ResumeCast(firedCast)
				expect.truthy(
					Framework.waitFor(function()
						return hitInstance ~= nil
					end, HIT_TIMEOUT),
					"cast did not resume after ResumeCast"
				)
				expect.equal(hitInstance, wall, "resumed cast hit the wrong instance")

				caster:Destroy()
				arena:Destroy()
			end)

			test("worker OnStep runs before movement and can steer a cast", function(expect)
				local arena = createArena()
				local wall = createWall(arena, Vector3.new(0, 0, -20), Vector3.new(50, 50, 2))
				local container = createContainer(arena)
				local behavior = makeBehavior(container)
				behavior.FastCastEventsModuleConfig.UseOnStep = true
				behavior.UserData = {
					OnStepVelocity = Vector3.new(0, 0, -120),
				}

				local hitInstance = nil
				local caster = createParallelCaster({
					Hit = function(_, result)
						hitInstance = result.Instance
					end,
				})
				caster:SetFastCastEventsModule(TestEventsModule)
				task.wait(0.25)

				fire(caster, "Raycast", Vector3.zero, Vector3.yAxis, 120, behavior)

				expect.truthy(
					Framework.waitFor(function()
						return hitInstance ~= nil
					end, HIT_TIMEOUT),
					"worker OnStep did not steer the cast into the wall"
				)
				expect.equal(hitInstance, wall, "OnStep steered the cast to the wrong instance")

				caster:Destroy()
				arena:Destroy()
			end)

			test("SetFastCastEventsModule forwards module events", function(expect)
				local arena = createArena()
				createWall(arena, Vector3.new(0, 0, -40), Vector3.new(50, 50, 2))
				local container = createContainer(arena)
				local behavior = makeBehavior(container)

				local signal = ReplicatedStorage:WaitForChild("FastCast2TestSignal") :: BindableEvent
				local received = {}

				local connection = signal.Event:Connect(function(name)
					received[name] = true
				end)

				local caster = createParallelCaster()
				caster:SetFastCastEventsModule(TestEventsModule)

				-- Let the worker VMs receive the new events module.
				task.wait(0.25)

				fire(caster, "Raycast", Vector3.new(0, 0, 0), Vector3.new(0, 0, -1), 120, behavior)

				expect.truthy(
					Framework.waitFor(function()
						return received.Hit == true
					end, HIT_TIMEOUT),
					"events module Hit never fired"
				)

				connection:Disconnect()
				caster:Destroy()
				arena:Destroy()
			end)

			test("events are Signals that support multiple listeners", function(expect)
				local arena = createArena()
				local wall = createWall(arena, Vector3.new(0, 0, -40), Vector3.new(50, 50, 2))
				local container = createContainer(arena)
				local behavior = makeBehavior(container)

				local firstCount = 0
				local secondCount = 0

				local caster = createParallelCaster()
				caster.Hit:Connect(function(_, result)
					if result.Instance == wall then
						firstCount += 1
					end
				end)
				caster.Hit:Connect(function(_, result)
					if result.Instance == wall then
						secondCount += 1
					end
				end)

				fire(caster, "Raycast", Vector3.new(0, 0, 0), Vector3.new(0, 0, -1), 120, behavior)

				expect.truthy(
					Framework.waitFor(function()
						return firstCount > 0 and secondCount > 0
					end, HIT_TIMEOUT),
					"parallel Signal listeners never fired"
				)

				caster:Destroy()
				arena:Destroy()
			end)

			test("SyncChangesToCast does not error", function(expect)
				local arena = createArena()
				local container = createContainer(arena)
				local behavior = makeBehavior(container)

				local firedCast = nil
				local caster = createParallelCaster({
					CastFire = function(cast)
						firedCast = cast
					end,
				})

				fire(caster, "Raycast", Vector3.new(0, 0, 0), Vector3.new(0, 1, 0), 60, behavior)
				expect.truthy(
					Framework.waitFor(function()
						return firedCast ~= nil
					end, HIT_TIMEOUT),
					"parallel CastFire never ran"
				)

				local cast = firedCast :: any
				FastCast:SetPositionCast(cast, Vector3.new(10, 10, 10))
				caster:SyncChangesToCast(cast)
				task.wait(0.1)

				expect.near(FastCast:GetPositionCast(cast), Vector3.new(10, 10, 10), 1e-3, "sync changed the local cast")

				FastCast:TerminateCast(cast)
				caster:Destroy()
				arena:Destroy()
			end)
		end),
	}
end
