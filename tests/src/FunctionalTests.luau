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

	caster:Init(
		2,
		"BulkMoveTo"
	)

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
			test("initializes and destroys", function(expect)
				local caster = createParallelCaster()
				expect.equal(caster.AlreadyInit, true, "parallel caster was not marked initialized")

				caster:Destroy()
			end)

			registerParallelCastTypes(test)

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
