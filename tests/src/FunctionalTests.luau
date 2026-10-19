--[[
	FastCast2 functional tests.

	These cover the checklist in TESTS.md: initialization, the three cast
	variants, every public event, movement modes, cast
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
				local events = behavior.FastCastEventsConfig
				local moduleEvents = behavior.FastCastEventsModuleConfig

				expect.equal(behavior.MaxDistance, 1000, "MaxDistance default changed")
				expect.equal(behavior.MaxLifetime, nil, "MaxLifetime should be unlimited by default")
				expect.near(behavior.Acceleration, Vector3.zero, 1e-6, "Acceleration default changed")
				expect.equal(
					behavior.HighFidelityBehavior,
					FastCastEnums.HighFidelityBehavior.Default,
					"HighFidelityBehavior default changed"
				)
				expect.equal(behavior.HighFidelitySegmentSize, 0.5, "HighFidelitySegmentSize default changed")
				expect.equal(behavior.CosmeticBulletTemplate, nil, "CosmeticBulletTemplate default changed")
				expect.equal(behavior.CosmeticBulletContainer, nil, "CosmeticBulletContainer default changed")
				expect.equal(behavior.AutoIgnoreContainer, true, "AutoIgnoreContainer default changed")
				expect.equal(behavior.CloneTemplate, true, "CloneTemplate should be enabled by default")
				expect.equal(behavior.VisualizeCasts, false, "VisualizeCasts should be disabled by default")
				expect.equal(type(behavior.VisualizeCastSettings), "table", "visualization settings are missing")
				expect.equal(events.UseLengthChanged, false, "LengthChanged should be opt-in")
				expect.equal(events.UseHit, true, "Hit should be enabled by default")
				expect.equal(events.UsePierced, true, "Pierced should be enabled by default")
				expect.equal(events.UseCastTerminating, true, "CastTerminating should be enabled by default")
				expect.equal(events.UseCanPierce, true, "CanPierce should be enabled by default")
				expect.equal(events.UseCastFire, true, "CastFire should be enabled by default")
				expect.equal(moduleEvents.UseLengthChanged, false, "module LengthChanged should be opt-in")
				expect.equal(moduleEvents.UseHit, true, "module Hit should be enabled by default")
				expect.equal(moduleEvents.UsePierced, true, "module Pierced should be enabled by default")
				expect.equal(moduleEvents.UseCastTerminating, true, "module CastTerminating should be enabled by default")
				expect.equal(moduleEvents.UseCanPierce, true, "module CanPierce should be enabled by default")
				expect.equal(moduleEvents.UseCastFire, true, "module CastFire should be enabled by default")
				expect.equal(moduleEvents.UseOnStep, false, "module OnStep should be opt-in")
			end)

			test("newBehavior returns independent nested configuration", function(expect)
				local first = FastCast.newBehavior()
				local second = FastCast.newBehavior()

				first.FastCastEventsConfig.UseHit = false
				first.FastCastEventsModuleConfig.UseHit = false
				first.VisualizeCastSettings.Debug_SegmentSize = 99

				expect.equal(second.FastCastEventsConfig.UseHit, true, "event config was shared between behaviors")
				expect.equal(second.FastCastEventsModuleConfig.UseHit, true, "module event config was shared between behaviors")
				expect.truthy(
					second.VisualizeCastSettings.Debug_SegmentSize ~= 99,
					"visualization settings were shared between behaviors"
				)
			end)
		end),

		Framework.describe("FastCast — Shared API coverage", function(test)
			registerParallelCastTypes(test)
			test("RaycastParams filters the first wall and hits the next", function(expect)
				local arena = createArena()
				local ignoredWall = createWall(arena, Vector3.new(0, 0, -20), Vector3.new(50, 50, 2))
				local targetWall = createWall(arena, Vector3.new(0, 0, -40), Vector3.new(50, 50, 2))
				local container = createContainer(arena)
				local behavior = makeBehavior(container)
				local params = RaycastParams.new()
				params.FilterType = Enum.RaycastFilterType.Exclude
				params.FilterDescendantsInstances = { container, ignoredWall }
				behavior.RaycastParams = params

				local hitInstance = nil
				local caster = createParallelCaster({
					Hit = function(_, result)
						hitInstance = result.Instance
					end,
				})
				fire(caster, "Raycast", Vector3.zero, Vector3.new(0, 0, -1), 120, behavior)

				expect.truthy(Framework.waitFor(function()
					return hitInstance ~= nil
				end, HIT_TIMEOUT), "filtered cast never hit a wall")
				expect.equal(hitInstance, targetWall, "RaycastParams did not exclude the first wall")

				caster:Destroy()
				arena:Destroy()
			end)

			test("MaxDistance terminates without reporting a hit", function(expect)
				local arena = createArena()
				local container = createContainer(arena)
				local behavior = makeBehavior(container)
				behavior.MaxDistance = 15

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

				expect.truthy(Framework.waitFor(function()
					return terminationCount > 0
				end, HIT_TIMEOUT), "cast did not terminate at MaxDistance")
				task.wait(0.1)
				expect.equal(hitCount, 0, "MaxDistance termination incorrectly reported a hit")
				expect.equal(terminationCount, 1, "MaxDistance termination fired more than once")

				caster:Destroy()
				arena:Destroy()
			end)

			test("cosmetic template is cloned into its container and ignored by its own cast", function(expect)
				local arena = createArena()
				local container = createContainer(arena)
				local template = Instance.new("Part")
				template.Name = "CosmeticTemplate"
				template.Anchored = true
				template.CanCollide = false
				template.CanQuery = true
				template.Parent = arena

				local targetWall = createWall(arena, Vector3.new(0, 0, -40), Vector3.new(50, 50, 2))
				local behavior = makeBehavior(container)
				behavior.CosmeticBulletTemplate = template
				behavior.CosmeticBulletContainer = container
				behavior.AutoIgnoreContainer = true

				local hitInstance = nil
				local caster = createParallelCaster({
					Hit = function(_, result)
						hitInstance = result.Instance
					end,
				})
				fire(caster, "Raycast", Vector3.zero, Vector3.new(0, 0, -1), 120, behavior)

				expect.truthy(Framework.waitFor(function()
					return hitInstance ~= nil
				end, HIT_TIMEOUT), "cast with cosmetic template never hit")
				expect.equal(hitInstance, targetWall, "cast hit its cosmetic projectile instead of the wall")
				expect.equal(#container:GetChildren(), 1, "cosmetic template was not cloned into its container")
				expect.truthy(container:GetChildren()[1] ~= template, "cosmetic projectile reused the template")

				caster:Destroy()
				arena:Destroy()
			end)

			test("CloneTemplate false uses the supplied cosmetic instance", function(expect)
				local arena = createArena()
				local container = createContainer(arena)
				local template = Instance.new("Part")
				template.Name = "CosmeticInstance"
				template.Anchored = true
				template.CanCollide = false
				template.Parent = arena

				local behavior = makeBehavior(container)
				behavior.CosmeticBulletTemplate = template
				behavior.CosmeticBulletContainer = container
				behavior.CloneTemplate = false

				local caster = createParallelCaster()
				fire(caster, "Raycast", Vector3.zero, Vector3.yAxis, 120, behavior)
				expect.truthy(Framework.waitFor(function()
					return template.Parent == container
				end, HIT_TIMEOUT), "supplied cosmetic instance was not moved into the container")
				expect.equal(#container:GetChildren(), 1, "CloneTemplate false unexpectedly created a clone")
				expect.equal(container:GetChildren()[1], template, "supplied cosmetic instance was not reused")

				caster:Destroy()
				arena:Destroy()
			end)

			test("event configuration can disable callback channels", function(expect)
				local arena = createArena()
				createWall(arena, Vector3.new(0, 0, -40), Vector3.new(50, 50, 2))
				local container = createContainer(arena)
				local behavior = makeBehavior(container)
				behavior.FastCastEventsConfig.UseHit = false
				behavior.FastCastEventsConfig.UseCastFire = false
				behavior.FastCastEventsConfig.UseCastTerminating = false

				local hitCount = 0
				local castFireCount = 0
				local terminationCount = 0
				local caster = createParallelCaster({
					Hit = function()
						hitCount += 1
					end,
					CastFire = function()
						castFireCount += 1
					end,
					CastTerminating = function()
						terminationCount += 1
					end,
				})
				fire(caster, "Raycast", Vector3.zero, Vector3.new(0, 0, -1), 120, behavior)
				task.wait(0.5)

				expect.equal(hitCount, 0, "disabled Hit callback still fired")
				expect.equal(castFireCount, 0, "disabled CastFire callback still fired")
				expect.equal(terminationCount, 0, "disabled CastTerminating callback still fired")

				caster:Destroy()
				arena:Destroy()
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


		end),

		Framework.describe("FastCast — Parallel-specific coverage", function(test)
			-- Mark the start of tests that cover Parallel-specific behavior.
			print("FASTCAST2 PARALLEL-ONLY TESTS")
			test("initializes shared runtime and creates casters", function(expect)
				FastCast.Init(2, "BulkMoveTo")
				local caster = createParallelCaster()
				expect.equal(type(caster.CasterId), "number", "caster did not receive a numeric ID")

				caster:Destroy()
			end)

			registerParallelCastTypes(test)

			test("CastFire exposes documented data for all cast variants", function(expect)
				local arena = createArena()
				local container = createContainer(arena)
				local behavior = makeBehavior(container)
				behavior.MaxLifetime = 3
				behavior.HighFidelitySegmentSize = 0.25
				behavior.UserData = { TestTag = "parallel" }

				local received = {}
				local caster = createParallelCaster({
					CastFire = function(cast)
						received[cast.Type] = cast
					end,
				})
				for _, castType in CAST_TYPES do
					fire(caster, castType, Vector3.zero, Vector3.new(0, 0, -1), 120, behavior)
				end

				expect.truthy(
					Framework.waitFor(function()
						return received[FastCast.CastType.Raycast]
							and received[FastCast.CastType.Blockcast]
							and received[FastCast.CastType.Spherecast]
					end, HIT_TIMEOUT),
					"CastFire did not expose all three cast variants"
				)

				for _, castType in CAST_TYPES do
					local cast = received[FastCast.CastType[castType]]
					expect.truthy(cast, castType .. " cast data was missing")
					expect.equal(cast.CasterId, caster.CasterId, castType .. " CasterId was wrong")
					expect.equal(cast.Type, FastCast.CastType[castType], castType .. " type was wrong")
					expect.equal(type(cast.ID), "number", castType .. " cast ID was not numeric")
					expect.equal(cast.StateInfo.Trajectory.Origin, Vector3.zero, castType .. " origin was wrong")
					expect.equal(
						cast.StateInfo.Trajectory.InitialVelocity,
						Vector3.new(0, 0, -120),
						castType .. " initial velocity was wrong"
					)
					expect.equal(cast.StateInfo.Trajectory.Acceleration, behavior.Acceleration, castType .. " acceleration was wrong")
					expect.equal(cast.StateInfo.MaxLifetime, behavior.MaxLifetime, castType .. " MaxLifetime was not copied")
					expect.equal(cast.StateInfo.HighFidelitySegmentSize, 0.25, castType .. " segment size was not copied")
					expect.equal(cast.UserData.TestTag, "parallel", castType .. " UserData was not copied")
					expect.equal(cast.RayInfo.WorldRoot, workspace, castType .. " WorldRoot was wrong")
					expect.equal(cast.RayInfo.MaxDistance, behavior.MaxDistance, castType .. " MaxDistance was wrong")
					expect.equal(typeof(cast.RayInfo.Parameters), "RaycastParams", castType .. " RaycastParams was missing")
					if castType == "Blockcast" then
						expect.equal(cast.RayInfo.Size, Vector3.one, "Blockcast size was not exposed")
					elseif castType == "Spherecast" then
						expect.equal(cast.RayInfo.Radius, 0.5, "Spherecast radius was not exposed")
					end
					FastCast:TerminateCast(cast)
				end

				caster:Destroy()
				arena:Destroy()
			end)

			test("one caster can fire again after its first shot terminates", function(expect)
				local arena = createArena()
				local wall = createWall(arena, Vector3.new(0, 0, -40), Vector3.new(50, 50, 2))
				local container = createContainer(arena)
				local behavior = makeBehavior(container)

				local castFireCount = 0
				local hitCount = 0
				local caster = createParallelCaster({
					CastFire = function()
						castFireCount += 1
					end,
					Hit = function(_, result)
						if result.Instance == wall then
							hitCount += 1
						end
					end,
				})

				-- Let the first shot finish before queueing more shots on the same caster.
				caster:RaycastFire(Vector3.zero, Vector3.new(0, 0, -1), 120, behavior)
				expect.truthy(
					Framework.waitFor(function()
						return castFireCount == 1 and hitCount == 1
					end, HIT_TIMEOUT),
					"the first shot did not fire and hit"
				)

				-- Fire repeatedly after a completed cast, including several requests in one frame.
				for _ = 2, 5 do
					caster:RaycastFire(Vector3.zero, Vector3.new(0, 0, -1), 120, behavior)
				end

				expect.truthy(
					Framework.waitFor(function()
						return castFireCount == 5 and hitCount == 5
					end, HIT_TIMEOUT),
					"subsequent shots were not all dispatched and hit the wall"
				)
				expect.equal(castFireCount, 5, "the same caster did not dispatch all five shots")
				expect.equal(hitCount, 5, "the same caster did not register all five hits")

				caster:Destroy()
				arena:Destroy()
			end)

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

			test("SyncChangesToCast updates UserData used by worker OnStep", function(expect)
				local arena = createArena()
				local wall = createWall(arena, Vector3.new(0, 0, -20), Vector3.new(50, 50, 2))
				local container = createContainer(arena)
				local behavior = makeBehavior(container)
				behavior.FastCastEventsModuleConfig.UseOnStep = true
				behavior.UserData = {
					OnStepVelocity = Vector3.yAxis * 120,
				}

				local hitInstance = nil
				local caster: any
				caster = createParallelCaster({
					CastFire = function(cast)
						-- Hold the cast until the updated UserData reaches the worker.
						FastCast:PauseCast(cast)
						cast.UserData = {
							OnStepVelocity = Vector3.new(0, 0, -120),
						}
						caster:SyncChangesToCast(cast)
						FastCast:ResumeCast(cast)
					end,
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
					"worker OnStep did not receive the updated UserData"
				)
				expect.equal(hitInstance, wall, "updated UserData did not steer the cast to the wall")

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

			test("SyncChangesToCast preserves worker-owned runtime and trajectory references", function(expect)
				local arena = createArena()
				local container = createContainer(arena)
				local behavior = makeBehavior(container)
				local firedCast = nil
				local caster = createParallelCaster({
					CastFire = function(cast)
						firedCast = cast
					end,
				})

				fire(caster, "Raycast", Vector3.zero, Vector3.yAxis, 60, behavior)
				expect.truthy(Framework.waitFor(function()
					return firedCast ~= nil
				end, HIT_TIMEOUT), "parallel CastFire never ran")

				local cast = firedCast :: any
				local trajectory = cast.StateInfo.Trajectory
				local totalRuntime = cast.StateInfo.TotalRuntime
				local distanceCovered = cast.StateInfo.DistanceCovered

				FastCast:SetVelocityCast(cast, Vector3.new(0, 0, -100))
				caster:SyncChangesToCast(cast)
				task.wait(0.1)

				expect.equal(cast.StateInfo.Trajectory, trajectory, "trajectory table reference changed")
				expect.equal(cast.StateInfo.TotalRuntime, totalRuntime, "sync overwrote worker-owned runtime")
				expect.equal(cast.StateInfo.DistanceCovered, distanceCovered, "sync overwrote worker-owned distance")
				expect.near(FastCast:GetVelocityCast(cast), Vector3.new(0, 0, -100), 1e-3, "trajectory change was not applied")

				FastCast:TerminateCast(cast)
				caster:Destroy()
				arena:Destroy()
			end)

			test("SyncChangesToCast refreshes the cached MaxDistance", function(expect)
				local arena = createArena()
				local container = createContainer(arena)
				local behavior = makeBehavior(container)
				behavior.FastCastEventsConfig.UseCastTerminating = true

				local firedCast = nil
				local terminationCount = 0
				local caster = createParallelCaster({
					CastFire = function(cast)
						firedCast = cast
						FastCast:PauseCast(cast)
					end,
					CastTerminating = function()
						terminationCount += 1
					end,
				})

				fire(caster, "Raycast", Vector3.zero, Vector3.yAxis, 120, behavior)
				expect.truthy(
					Framework.waitFor(function()
						return firedCast ~= nil
					end, HIT_TIMEOUT),
					"parallel CastFire never ran"
				)

				local cast = firedCast :: any
				cast.RayInfo.MaxDistance = 1
				caster:SyncChangesToCast(cast)
				FastCast:ResumeCast(cast)

				expect.truthy(
					Framework.waitFor(function()
						return terminationCount == 1
					end, HIT_TIMEOUT),
					"worker did not use the updated MaxDistance cache"
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
