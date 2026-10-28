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
local VISUALIZE_CASTS = true

local arenaCounter = 0

local function createArena(expect: any?): Folder
	arenaCounter += 1
	local arena = Instance.new("Folder")
	arena.Name = "FastCast2TestArena" .. arenaCounter
	arena.Parent = workspace
	if expect then
		expect.cleanup(function()
			if arena.Parent then
				arena:Destroy()
			end
		end)
	end
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
	behavior.VisualizeCasts = VISUALIZE_CASTS
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

-- Use the matching WorldRoot query to make sure the newly-created test wall is
-- visible to spatial queries before involving the parallel worker.
local function queryDirect(
	castType: string,
	origin: Vector3,
	direction: Vector3,
	params: RaycastParams
): RaycastResult?
	local displacement = direction.Unit * 20
	if castType == "Blockcast" then
		return workspace:Blockcast(CFrame.new(origin), Vector3.one, displacement, params)
	elseif castType == "Spherecast" then
		return workspace:Spherecast(origin, 0.5, displacement, params)
	end
	return workspace:Raycast(origin, displacement, params)
end

local function createParallelCaster(events: { [string]: any }?, expect: any?): any
	local caster = FastCast.new()

	for name, fn in events or {} do
		caster[name] = fn
	end

	if expect then
		expect.cleanup(function()
			if caster.CasterId ~= nil and not caster._destroying then
				caster:Destroy()
			end
		end)
	end

	return caster
end

-- IMPORTANT: Keep bounded retries for tests that depend on Roblox's spatial
-- query/frame scheduling. These tests can be intermittent even with correct
-- code; do not remove the retry policy or collapse it to one attempt. Every
-- attempt must use a fresh scene and caster, clean them up, and still fail after
-- all attempts if the expected behavior is never observed.
local function retry(
	attempts: number,
	delayBetweenAttempts: number,
	runAttempt: (number) -> boolean
): (boolean, string)
	local lastFailure = "no attempt ran"
	for attempt = 1, attempts do
		local succeeded, failure = runAttempt(attempt)
		if succeeded then
			return true, failure or lastFailure
		end
		lastFailure = failure or ("attempt " .. tostring(attempt) .. " failed")
		if attempt < attempts then
			task.wait(delayBetweenAttempts)
		end
	end
	return false, lastFailure
end

local function registerParallelCastTypes(test: (string, any) -> ())
	for _, castType in CAST_TYPES do
		test(castType .. " reaches a wall", function(expect)
			-- Spatial-query readiness can be frame-dependent in Studio. Retry
			-- with a fresh scene/caster, but first prove the matching direct query
			-- can hit this attempt's wall. This keeps a missing FastCast hit
			-- distinguishable from geometry that is not queryable yet.
			local succeeded, lastFailure = retry(3, 0.1, function(attempt)
				local arena = createArena()
				local wall = createWall(arena, Vector3.new(0, 0, -12), Vector3.new(50, 50, 2))
				local container = createContainer(arena)
				local behavior = makeBehavior(container)
				behavior.HighFidelityBehavior = FastCastEnums.HighFidelityBehavior.Always
				behavior.HighFidelitySegmentSize = 1

				local directResult = nil
				local directReady = Framework.waitFor(function()
					directResult = queryDirect(
						castType,
						Vector3.zero,
						Vector3.new(0, 0, -1),
						behavior.RaycastParams
					)
					return directResult ~= nil and directResult.Instance == wall
				end, 1.5)

				if not directReady then
					local detail = string.format(
						"attempt %d: direct %s query did not hit setup wall (instance=%s)",
						attempt,
						castType,
						tostring(directResult and directResult.Instance)
					)
					arena:Destroy()
					return false, detail
				end

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

				fire(caster, castType, Vector3.zero, Vector3.new(0, 0, -1), 120, behavior)

				local hitObserved = Framework.waitFor(function()
					return hitInstance ~= nil
				end, 1.5)
				local terminationObserved = hitObserved and Framework.waitFor(function()
					return terminated
				end, 1.5)

				local correctHit = hitObserved and hitInstance == wall
				local detail = string.format(
					"attempt %d: direct query=wall, FastCast hit=%s, terminated=%s",
					attempt,
					tostring(hitInstance),
					tostring(terminated)
				)

				caster:Destroy()
				Framework.waitFor(function()
					return caster.CasterId == nil
				end, 1)
				arena:Destroy()

				if not correctHit or not terminationObserved then
					return false, detail
				end
				return true, detail
			end)

			expect.truthy(
				succeeded,
				castType .. " did not hit and terminate after 3 fresh attempts (" .. lastFailure .. ")"
			)
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
			test("initializes shared runtime and creates casters", function(expect)
				FastCast.Init(2, "BulkMoveTo")
				local caster = createParallelCaster(nil, expect)
				expect.equal(type(caster.CasterId), "number", "caster did not receive a numeric ID")

				caster:Destroy()
			end)

			test("Stop pauses simulation and Init resumes it", function(expect)
				local arena = createArena(expect)
				local wall = createWall(arena, Vector3.new(0, 0, -100), Vector3.new(50, 50, 2))
				local container = createContainer(arena)
				local behavior = makeBehavior(container)
				local hitInstance = nil
				local castFired = false

				local caster = createParallelCaster({
					CastFire = function()
						castFired = true
					end,
					Hit = function(_, result)
						hitInstance = result.Instance
					end,
				}, expect)

				fire(caster, "Raycast", Vector3.zero, Vector3.new(0, 0, -1), 120, behavior)
				expect.truthy(
					Framework.waitFor(function()
						return castFired
					end, HIT_TIMEOUT),
					"CastFire did not fire before stopping simulation"
				)

				FastCast.Stop()
				task.wait(0.1)
				expect.equal(hitInstance, nil, "cast advanced while simulation was stopped")

				FastCast.Init(2)
				expect.truthy(
					Framework.waitFor(function()
						return hitInstance ~= nil
					end, HIT_TIMEOUT),
					"active cast did not resume after Init"
				)
				expect.equal(hitInstance, wall, "resumed cast hit the wrong instance")

				caster:Destroy()
				arena:Destroy()
			end)

			registerParallelCastTypes(test)
			test("RaycastParams filters the first wall and hits the next", function(expect)
			local succeeded, lastFailure = retry(3, 0.1, function(attempt)
				local arena = createArena()
				local ignoredWall = createWall(arena, Vector3.new(0, 0, -5), Vector3.new(50, 50, 4))
				local targetWall = createWall(arena, Vector3.new(0, 0, -12), Vector3.new(50, 50, 6))
				local container = createContainer(arena)
				local behavior = makeBehavior(container)
				local params = RaycastParams.new()
				params.FilterType = Enum.RaycastFilterType.Exclude
				params.FilterDescendantsInstances = { container, ignoredWall }
				behavior.RaycastParams = params

				-- Let newly-created geometry enter Roblox's spatial query data before
				-- validating both the source params and the cast's cloned params.
				task.wait()
				local directResult = workspace:Raycast(Vector3.zero, Vector3.new(0, 0, -20), params)
				if not directResult or directResult.Instance ~= targetWall then
					local detail = "attempt " .. tostring(attempt) .. ": direct query did not reach target wall"
					arena:Destroy()
					return false, detail
				end

				local hitInstance = nil
				local clonedParamsResult = nil
				local caster = createParallelCaster({
					CastFire = function(cast)
						clonedParamsResult = workspace:Raycast(
							Vector3.zero,
							Vector3.new(0, 0, -20),
							cast.RayInfo.Parameters
						)
					end,
					Hit = function(_, result)
						hitInstance = result.Instance
					end,
				})
				fire(caster, "Raycast", Vector3.zero, Vector3.new(0, 0, -1), 120, behavior)

				local hitObserved = Framework.waitFor(function()
					return hitInstance ~= nil
				end, 1.5)
				local clonedTarget = clonedParamsResult and clonedParamsResult.Instance == targetWall
				local correctHit = hitObserved and hitInstance == targetWall
				local detail = string.format(
					"attempt %d: hit=%s, cloned params target=%s, direct target=%s",
					attempt,
					tostring(hitInstance),
					tostring(clonedTarget),
					tostring(directResult.Instance == targetWall)
				)

				caster:Destroy()
				arena:Destroy()
				if not correctHit then
					task.wait(0.1)
					return false, detail
				end
				return true, detail
			end)

			expect.truthy(
				succeeded,
				"filtered cast did not hit the second wall after 3 fresh attempts (" .. lastFailure .. ")"
			)
		end)

			test("InitialOffset initializes and updates the cosmetic cast transform", function(expect)
				local arena = createArena(expect)
				local container = createContainer(arena)
				local behavior = makeBehavior(container)
				local initialOffset = CFrame.new(0, 0, -2) * CFrame.Angles(0, math.rad(90), 0)
				behavior.InitialOffset = initialOffset
				behavior.CosmeticBulletTemplate = Instance.new("Part")
				behavior.CosmeticBulletTemplate.Anchored = true
				-- Keep the source template out of the cast path; only its clone belongs there.
				behavior.CosmeticBulletTemplate.Position = Vector3.new(1000, 0, 1000)
				behavior.CosmeticBulletTemplate.Parent = arena

				local firedCast = nil
				local caster = createParallelCaster({
					CastFire = function(cast)
						firedCast = cast
					end,
				}, expect)

				-- Zero initial velocity makes the spawn transform stable while the
				-- asynchronous parallel CastFire event is delivered to this test.
				fire(caster, "Raycast", Vector3.zero, Vector3.new(0, 0, -1), 0, behavior)
				expect.truthy(
					Framework.waitFor(function()
						return firedCast ~= nil and firedCast.RayInfo.CosmeticBulletObject ~= nil
					end, HIT_TIMEOUT),
					"CastFire did not expose the cosmetic cast"
				)

				local cast = firedCast :: any
				local cosmetic = cast.RayInfo.CosmeticBulletObject
				expect.equal(cast.Offset, initialOffset, "InitialOffset was not copied to cast.Offset")
				expect.equal(cosmetic.CFrame, cast.CFrame, "initial cosmetic transform did not include Offset")

				local previousPosition = cosmetic.Position
				FastCast:SetVelocityCast(cast, Vector3.new(0, 0, -30))
				cast.Offset = CFrame.new(100, 0, 0)
				FastCast:SyncChangesToCast(cast)

				expect.truthy(
					Framework.waitFor(function()
						return (cosmetic.Position - previousPosition).Magnitude > 50
					end, HIT_TIMEOUT),
					"runtime Offset was not applied to the cosmetic bullet"
				)
				-- cast.CFrame is a public read-only simulation value, not a live
				-- worker-to-main-thread synchronization channel. The runtime Offset
				-- contract is verified through the cosmetic bullet above.

				caster:Destroy()
				arena:Destroy()
		end)

			test("MaxPiercesPerStep reports pierced walls before the terminal hit", function(expect)
				local arena = createArena(expect)
				local firstWall = createWall(arena, Vector3.new(0, 0, -5), Vector3.new(50, 50, 2))
				local secondWall = createWall(arena, Vector3.new(0, 0, -12), Vector3.new(50, 50, 2))
				local targetWall = createWall(arena, Vector3.new(0, 0, -19), Vector3.new(50, 50, 2))
				local container = createContainer(arena)
				local behavior = makeBehavior(container)
				behavior.MaxPiercesPerStep = 3
				behavior.UserData = { PierceAll = true, TerminalWall = targetWall }

				local signal = ReplicatedStorage:WaitForChild("FastCast2TestSignal") :: BindableEvent
				local eventOrder = {}
				local connection = signal.Event:Connect(function(name, _cast, result)
					-- Only Hit/Pierced events carry a RaycastResult in this argument
					-- position. Ignore unrelated or malformed signal payloads.
					if typeof(result) == "RaycastResult" and (
						result.Instance == firstWall
						or result.Instance == secondWall
						or result.Instance == targetWall
					) then
						table.insert(eventOrder, {
							name = name,
							instance = result.Instance,
						})
					end
				end)

				local caster = createParallelCaster(nil, expect)
				caster:SetFastCastEventsModule(TestEventsModule)
				task.wait(0.25)
				fire(caster, "Raycast", Vector3.zero, Vector3.new(0, 0, -1), 1200, behavior)

				expect.truthy(
					Framework.waitFor(function()
						return #eventOrder >= 3
					end, HIT_TIMEOUT),
					"MaxPiercesPerStep did not report two pierces and a terminal hit"
				)
				expect.equal(eventOrder[1].name, "Pierced", "first event was not Pierced")
				expect.equal(eventOrder[1].instance, firstWall, "first pierced wall was incorrect")
				expect.equal(eventOrder[2].name, "Pierced", "second event was not Pierced")
				expect.equal(eventOrder[2].instance, secondWall, "second pierced wall was incorrect")
				expect.equal(eventOrder[3].name, "Hit", "terminal event was not Hit")
				expect.equal(eventOrder[3].instance, targetWall, "terminal hit was on the wrong wall")

				connection:Disconnect()
				caster:Destroy()
				arena:Destroy()
			end)

			test("MaxDistance terminates without reporting a hit", function(expect)
				local arena = createArena(expect)
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
				}, expect)
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
				local arena = createArena(expect)
				local container = createContainer(arena)
				local template = Instance.new("Part")
				template.Name = "CosmeticTemplate"
				template.Anchored = true
				template.CanCollide = false
				template.CanQuery = true
				template.Parent = arena

				local targetWall = createWall(arena, Vector3.new(0, 0, -12), Vector3.new(50, 50, 2))
				local behavior = makeBehavior(container)
				behavior.CosmeticBulletTemplate = template
				behavior.CosmeticBulletContainer = container
				behavior.AutoIgnoreContainer = true

				-- Ensure the wall is in spatial-query data before the asynchronous worker starts.
				expect.truthy(Framework.waitFor(function()
					local result = workspace:Raycast(
						Vector3.zero,
						Vector3.new(0, 0, -20),
						behavior.RaycastParams
					)
					return result ~= nil and result.Instance == targetWall
				end, HIT_TIMEOUT), "target wall never became queryable before cosmetic-template cast")

				local hitInstance = nil
				local caster = createParallelCaster({
					Hit = function(_, result)
						hitInstance = result.Instance
					end,
				}, expect)
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
				local arena = createArena(expect)
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

				local caster = createParallelCaster(nil, expect)
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
				local arena = createArena(expect)
				createWall(arena, Vector3.new(0, 0, -12), Vector3.new(50, 50, 2))
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
				}, expect)
				fire(caster, "Raycast", Vector3.zero, Vector3.new(0, 0, -1), 120, behavior)
				task.wait(0.2)

				expect.equal(hitCount, 0, "disabled Hit callback still fired")
				expect.equal(castFireCount, 0, "disabled CastFire callback still fired")
				expect.equal(terminationCount, 0, "disabled CastTerminating callback still fired")

				caster:Destroy()
				arena:Destroy()
			end)

			test("movement mode can be switched", function(expect)
				local caster = createParallelCaster(nil, expect)
				FastCast.SetMovementModeEnabled(true, "Motor6D")

				FastCast.SetMovementModeEnabled(true, "BulkMoveTo")
				caster:Destroy()
			end)

			test("cast velocity, acceleration and position can be manipulated", function(expect)
				local arena = createArena(expect)
				local container = createContainer(arena)
				local behavior = makeBehavior(container)
				local firedCast = nil

				local caster = createParallelCaster({
					CastFire = function(cast)
						firedCast = cast
					end,
				}, expect)

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
				FastCast:SyncChangesToCast(cast)

				expect.near(FastCast:GetVelocityCast(cast), Vector3.new(10, 0, -100), 1e-3, "velocity was not updated")
				expect.near(FastCast:GetAccelerationCast(cast), Vector3.new(0, -15, 0), 1e-3, "acceleration was not updated")
				expect.near(FastCast:GetPositionCast(cast), Vector3.new(6, 5, 5), 1e-3, "position was not updated")

				FastCast:SetVelocity(cast, Vector3.new(1, 2, 3))
				FastCast:SetAcceleration(cast, Vector3.new(4, 5, 6))
				FastCast:SyncChangesToCast(cast)
				expect.near(FastCast:GetVelocityCast(cast), Vector3.new(1, 2, 3), 1e-3, "SetVelocity alias did not update velocity")
				expect.near(FastCast:GetAccelerationCast(cast), Vector3.new(4, 5, 6), 1e-3, "SetAcceleration alias did not update acceleration")

				FastCast:TerminateCast(cast)
				caster:Destroy()
				arena:Destroy()
			end)

			test("HighFidelity Always still resolves a hit", function(expect)
				local arena = createArena(expect)
				local wall = createWall(arena, Vector3.new(0, 0, -12), Vector3.new(50, 50, 2))
				local container = createContainer(arena)
				local behavior = makeBehavior(container)
				behavior.HighFidelityBehavior = FastCastEnums.HighFidelityBehavior.Always
				behavior.HighFidelitySegmentSize = 1

				-- Roblox may not include newly-parented parts in spatial queries
				-- immediately. Ensure the wall is queryable before the worker starts
				-- advancing this fast cast, or it can pass through during that delay.
				expect.truthy(
					Framework.waitFor(function()
						local result = workspace:Raycast(
							Vector3.zero,
							Vector3.new(0, 0, -20),
							behavior.RaycastParams
						)
						return result ~= nil and result.Instance == wall
					end, HIT_TIMEOUT),
					"test wall never became queryable before the high-fidelity cast"
				)

				local hitInstance = nil
				local caster = createParallelCaster({
					Hit = function(_, result)
						hitInstance = result.Instance
					end,
				}, expect)

				fire(caster, "Raycast", Vector3.new(0, 0, 0), Vector3.new(0, 0, -1), 120, behavior)
				expect.truthy(Framework.waitFor(function()
					return hitInstance ~= nil
				end, HIT_TIMEOUT), "high-fidelity cast never hit the wall")
				expect.equal(hitInstance, wall, "high-fidelity cast hit the wrong instance")

				caster:Destroy()
				arena:Destroy()
			end)

			test("HighFidelity Always terminates when MaxDistance is reached", function(expect)
				local arena = createArena(expect)
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
				}, expect)

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
				local arena = createArena(expect)
				local container = createContainer(arena)
				local behavior = makeBehavior(container)
				behavior.MaxLifetime = 0.1

				local terminatedRuntime = nil
				local caster = createParallelCaster({
					CastTerminating = function(cast)
						terminatedRuntime = cast.StateInfo.TotalRuntime
					end,
				}, expect)
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
				local arena = createArena(expect)
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
				}, expect)
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
				local arena = createArena(expect)
				local wall = createWall(arena, Vector3.new(0, 0, -12), Vector3.new(50, 50, 2))
				local container = createContainer(arena)
				local behavior = makeBehavior(container)

				local firstCount = 0
				local secondCount = 0

				local caster = createParallelCaster(nil, expect)
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

				-- Allow the worker VMs to finish initialization and the wall to
				-- enter spatial-query data before testing Signal delivery.
				task.wait(0.25)
				expect.truthy(
					Framework.waitFor(function()
						local result = workspace:Raycast(
							Vector3.zero,
							Vector3.new(0, 0, -20),
							behavior.RaycastParams
						)
						return result ~= nil and result.Instance == wall
					end, HIT_TIMEOUT),
					"signal-test wall never became queryable"
				)

				fire(caster, "Raycast", Vector3.new(0, 0, 0), Vector3.new(0, 0, -1), 120, behavior)

				expect.truthy(
					Framework.waitFor(function()
						return firstCount > 0 and secondCount > 0
					end, HIT_TIMEOUT),
					string.format(
						"parallel Signal listeners never fired (first=%d, second=%d)",
						firstCount,
						secondCount
					)
				)

				caster:Destroy()
				arena:Destroy()
			end)


		end),

		Framework.describe("FastCast — Parallel-specific coverage", function(test)
			-- Mark the start of tests that cover Parallel-specific behavior.
			print("FASTCAST2 PARALLEL-ONLY TESTS")
			registerParallelCastTypes(test)

			test("CastFire exposes documented data for all cast variants", function(expect)
				local arena = createArena(expect)
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
				}, expect)
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
				local arena = createArena(expect)
				local wall = createWall(arena, Vector3.new(0, 0, -12), Vector3.new(50, 50, 2))
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
				}, expect)

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
				}, expect)
				local casterB = createParallelCaster({
					CastFire = function(cast)
						casterBId = cast.CasterId
					end,
				}, expect)

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
				local arena = createArena(expect)
				local wall = createWall(arena, Vector3.new(0, 0, -12), Vector3.new(50, 50, 2))
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
				}, expect)

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
				local arena = createArena(expect)
				local wall = createWall(arena, Vector3.new(0, 0, -12), Vector3.new(50, 50, 2))
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
				}, expect)
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

			test("FastCast:SyncChangesToCast updates UserData used by worker OnStep", function(expect)
				local arena = createArena(expect)
				local wall = createWall(arena, Vector3.new(0, 0, -12), Vector3.new(50, 50, 2))
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
						FastCast:SyncChangesToCast(cast)
						FastCast:ResumeCast(cast)
					end,
					Hit = function(_, result)
						hitInstance = result.Instance
					end,
				}, expect)

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
				local arena = createArena(expect)
				createWall(arena, Vector3.new(0, 0, -12), Vector3.new(50, 50, 2))
				local container = createContainer(arena)
				local behavior = makeBehavior(container)
				behavior.HighFidelityBehavior = FastCastEnums.HighFidelityBehavior.Always
				behavior.HighFidelitySegmentSize = 1

				local signal = ReplicatedStorage:WaitForChild("FastCast2TestSignal") :: BindableEvent
				local received = {}

				local connection = signal.Event:Connect(function(name)
					received[name] = true
				end)

				local caster = createParallelCaster(nil, expect)
				caster:SetFastCastEventsModule(TestEventsModule)

				-- Let the worker VMs receive the new events module.
				task.wait(0.25)

				-- Ensure the wall is visible to spatial queries before starting
				-- the worker cast, so this test isolates module-event forwarding.
				expect.truthy(
					Framework.waitFor(function()
						local result = workspace:Raycast(
							Vector3.zero,
							Vector3.new(0, 0, -20),
							behavior.RaycastParams
						)
						return result ~= nil and result.Instance:IsDescendantOf(arena)
					end, HIT_TIMEOUT),
					"events-module test wall never became queryable"
				)

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

			test("FastCast:SyncChangesToCast preserves worker-owned runtime and trajectory references", function(expect)
				local arena = createArena(expect)
				local container = createContainer(arena)
				local behavior = makeBehavior(container)
				local firedCast = nil
				local caster = createParallelCaster({
					CastFire = function(cast)
						firedCast = cast
					end,
				}, expect)

				fire(caster, "Raycast", Vector3.zero, Vector3.yAxis, 60, behavior)
				expect.truthy(Framework.waitFor(function()
					return firedCast ~= nil
				end, HIT_TIMEOUT), "parallel CastFire never ran")

				local cast = firedCast :: any
				local trajectory = cast.StateInfo.Trajectory
				local totalRuntime = cast.StateInfo.TotalRuntime
				local distanceCovered = cast.StateInfo.DistanceCovered

				FastCast:SetVelocityCast(cast, Vector3.new(0, 0, -100))
				FastCast:SyncChangesToCast(cast)
				task.wait(0.1)

				expect.equal(cast.StateInfo.Trajectory, trajectory, "trajectory table reference changed")
				expect.equal(cast.StateInfo.TotalRuntime, totalRuntime, "sync overwrote worker-owned runtime")
				expect.equal(cast.StateInfo.DistanceCovered, distanceCovered, "sync overwrote worker-owned distance")
				expect.near(FastCast:GetVelocityCast(cast), Vector3.new(0, 0, -100), 1e-3, "trajectory change was not applied")

				FastCast:TerminateCast(cast)
				caster:Destroy()
				arena:Destroy()
			end)

			test("FastCast:SyncChangesToCast refreshes the cached MaxDistance", function(expect)
				local arena = createArena(expect)
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
				}, expect)

				fire(caster, "Raycast", Vector3.zero, Vector3.yAxis, 120, behavior)
				expect.truthy(
					Framework.waitFor(function()
						return firedCast ~= nil
					end, HIT_TIMEOUT),
					"parallel CastFire never ran"
				)

				local cast = firedCast :: any
				cast.RayInfo.MaxDistance = 1
				FastCast:SyncChangesToCast(cast)
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

			test("FastCast:SyncChangesToCast does not error", function(expect)
				local arena = createArena(expect)
				local container = createContainer(arena)
				local behavior = makeBehavior(container)

				local firedCast = nil
				local caster = createParallelCaster({
					CastFire = function(cast)
						firedCast = cast
					end,
				}, expect)

				fire(caster, "Raycast", Vector3.new(0, 0, 0), Vector3.new(0, 1, 0), 60, behavior)
				expect.truthy(
					Framework.waitFor(function()
						return firedCast ~= nil
					end, HIT_TIMEOUT),
					"parallel CastFire never ran"
				)

				local cast = firedCast :: any
				FastCast:SetPositionCast(cast, Vector3.new(10, 10, 10))
				FastCast:SyncChangesToCast(cast)
				task.wait(0.1)

				expect.near(FastCast:GetPositionCast(cast), Vector3.new(10, 10, 10), 1e-3, "sync changed the local cast")

				FastCast:TerminateCast(cast)
				caster:Destroy()
				arena:Destroy()
			end)

			test("DestroyVMs tears down workers and Init recreates the runtime", function(expect)
				local caster = createParallelCaster({
					CastFire = function()
					end,
				}, expect)
				local behavior = FastCast.newBehavior()

				FastCast.DestroyVMs()
				expect.equal(caster.CasterId ~= nil, true, "DestroyVMs destroyed the caster object")

				local ok = pcall(function()
					caster:RaycastFire(Vector3.zero, Vector3.yAxis, 60, behavior)
				end)
				expect.equal(ok, false, "casts should require Init after DestroyVMs")

				FastCast.Init(2, "BulkMoveTo")
				local receivedCast = nil
				caster.CastFire:Connect(function(cast)
					receivedCast = cast
				end)
				caster:RaycastFire(Vector3.zero, Vector3.yAxis, 60, behavior)
				expect.truthy(Framework.waitFor(function()
					return receivedCast ~= nil
				end, HIT_TIMEOUT), "existing caster could not fire after runtime reinitialization")

				caster:Destroy()
			end)
		end),
	}
end
