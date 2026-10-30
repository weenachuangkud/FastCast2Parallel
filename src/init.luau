--[[
	Written by Eti the Spirit (18406183)
	
		The latest patch notes can be located here (and do note, the version at the top of this script might be outdated. I have a thing for forgetting to change it):
		>	https://etithespirit.github.io/FastCastAPIDocs/changelog
		
		*** If anything is broken, please don't hesitate to message me! ***
		
		YOU CAN FIND IMPORTANT USAGE INFORMATION HERE: https://etithespirit.github.io/FastCastAPIDocs
		YOU CAN FIND IMPORTANT USAGE INFORMATION HERE: https://etithespirit.github.io/FastCastAPIDocs
		YOU CAN FIND IMPORTANT USAGE INFORMATION HERE: https://etithespirit.github.io/FastCastAPIDocs
		
		YOU SHOULD ONLY CREATE ONE CASTER PER GUN.
		YOU SHOULD >>>NEVER<<< CREATE A NEW CASTER EVERY TIME THE GUN NEEDS TO BE FIRED.
		
		A caster (created with FastCast.new()) represents a "gun".
		When you consider a gun, you think of stats like accuracy, bullet speed, etc. This is the info a caster stores. 
	
	--
	
	This is a library used to create hitscan-based guns that simulate projectile physics.
	
	This means:
		- You don't have to worry about bullet lag / jittering
		- You don't have to worry about keeping bullets at a low speed due to physics being finnicky between clients
		- You don't have to worry about misfires in bullet's Touched event (e.g. where it may going so fast that it doesn't register)
		
	Hitscan-based guns are commonly seen in the form of laser beams, among other things. Hitscan simply raycasts out to a target
	and says whether it hit or not.
	
	Unfortunately, while reliable in terms of saying if something got hit or not, this method alone cannot be used if you wish
	to implement bullet travel time into a weapon. As a result of that, I made this library - an excellent remedy to this dilemma.
	
	FastCast is intended to be require()'d once in a script, as you can create as many casters as you need with FastCast.new()
	This is generally handy since you can store settings and information in these casters, and even send them out to other scripts via events
	for use.
	
	Remember -- A "Caster" represents an entire gun (or whatever is launching your projectiles), *NOT* the individual bullets.
	Make the caster once, then use the caster to fire your bullets. Do not make a caster for each bullet.
--]]

-- Mozilla Public License 2.0 (files originally from FastCast)

--[[
	- Modified by: Mawin CK 
	- Date : 2025

	NOTE:
	For anyone who's reading this is FastCast2, An improved version of FastCast with Parallel scripting, more extensions, and statically typed.
A powerful modern projectile library

	Because FastCast is no longer actively maintained by EtiTheSpirit, this repository continues the project with updates and adaptations.
	- Devforum: https://devforum.roblox.com/t/fastcast2-an-improved-version-of-fastcast-with-parallel-scripting-more-extensions-and-statically-typed-a-powerful-modern-projectile-library/4093890
]]



-- Services

--local HTTPService = game:GetService("HttpService")
--local RS = game:GetService("RunService")

-- Modules
--local BaseCast = script:WaitForChild("BaseCast")

-- Services

local RunService = game:GetService("RunService")

-- Requires
local Signal = require(script:WaitForChild("Signal"))
local TypeDef = require(script:WaitForChild("TypeDefinitions"))
local DefaultConfigs = require(script:WaitForChild("DefaultConfigs"))
local DispatcherModule = script:WaitForChild("FastCastVMs")
local Dispatcher = require(DispatcherModule)

-- Type Exports
export type FastCastEventsModule = TypeDef.FastCastEventsModule
export type FastCastEvents = TypeDef.FastCastEvents
export type FastCastSignalEvents = TypeDef.FastCastSignalEvents

export type CanPierceFunction = TypeDef.CanPierceFunction
export type OnHitFunction = TypeDef.OnHitFunction
export type OnPiercedFunction = TypeDef.OnPiercedFunction
export type OnLengthChangedFunction = TypeDef.OnLengthChangedFunction
export type OnCastTerminatingFunction = TypeDef.OnCastTerminatingFunction
export type OnCastFireFunction = TypeDef.OnCastFireFunction
export type OnStepFunction = TypeDef.OnStepFunction

export type VisualizeCastSettings = TypeDef.VisualizeCastSettings

export type CasterParallel = TypeDef.CasterParallel

export type FastCastBehavior = TypeDef.FastCastBehavior

export type CastTrajectory = TypeDef.CastTrajectory
export type CastStateInfo = TypeDef.CastStateInfo
export type CastRayInfo = TypeDef.CastRayInfo
export type BlockCastRayInfo = TypeDef.BlockCastRayInfo
export type SphereCastRayInfo = TypeDef.SphereCastRayInfo

export type BaseCastData = TypeDef.BaseCastData
export type ActiveCastData = TypeDef.ActiveCastData
export type ActiveBlockcastData = TypeDef.ActiveBlockcastData
export type ActiveSpherecastData = TypeDef.ActiveSpherecastData

-- Types
type vaildcast = TypeDef.ActiveCastData | TypeDef.ActiveBlockcastData | TypeDef.ActiveSpherecastData

-- CONSTANTS
local DEFAULT_CACHE_SIZE = 500
local DEFAULT_CACHE_HOLDER = workspace
local EventType = FastCastEnums.EventType

-- Events exposed on a Caster as a Signal. Assigning a function to one of these
-- names is equivalent to connecting that function to the underlying Signal.
local SIGNAL_EVENT_TYPES = {
	CastFire = EventType.CastFire,
	OnStep = EventType.OnStep,
	CastTerminating = EventType.CastTerminating,
	Hit = EventType.Hit,
	Pierced = EventType.Pierced,
	LengthChanged = EventType.LengthChanged
}

-- CanPierce is a query (it has to return a boolean), so it stays a plain function.
local QUERY_EVENTS = {
	["CanPierce"] = true
}

-- Mirrors the EVT_* numeric constants in ParallelSimulation. Parallel workers
-- send one "Batch" message per frame containing records tagged with these IDs;
-- the main thread demuxes them back into the Caster's signals.
local OUTPUT_EVENT_NAMES = {
	[EventType.LengthChanged] = "LengthChanged",
	[EventType.Hit] = "Hit",
	[EventType.Pierced] = "Pierced",
	[EventType.CastTerminating] = "CastTerminating",
	[EventType.OnStep] = "OnStep"
}

--[[
	Note: On the client, `PARALLEL_PARENT` must be a script-enabled container
	(for example `ReplicatedFirst`). Worker controllers placed in a container
	that does not run scripts never initialize, and no casts are simulated.
]]
-- Parallel luau related
local PARALLEL_PARENT
if RunService:IsServer() then
	PARALLEL_PARENT = game:GetService("ServerScriptService")
else
	PARALLEL_PARENT = game:GetService("ReplicatedFirst")
end
local VM_NAME = "FastCastVM"
local VM_CONTAINER_NAME = "FastCastVMsContainer"
local DISPATCHER_NAME = "FastCastVMs"

local function NewCasterSignals()
	return {
		CastFire = Signal.new(),
		OnStep = Signal.new(),
		CastTerminating = Signal.new(),
		Hit = Signal.new(),
		Pierced = Signal.new(),
		LengthChanged = Signal.new()
	}
end

local function DestroyCasterSignals(self)
	local legacy = rawget(self, "_legacy")
	if legacy then
		for _, connection in legacy do
			connection:Disconnect()
		end
		rawset(self, "_legacy", nil)
	end

	local events = rawget(self, "_events")
	if events then
		for _, signal in events do
			signal:Destroy()
		end
		rawset(self, "_events", nil)
	end

	rawset(self, "CanPierce", nil)
end

local function IndexCaster(self, key)
	local events = rawget(self, "_events")
	if events then
		local signal = events[key]
		if signal ~= nil then
			return signal
		end
	end

	local mt = getmetatable(self)
	if mt then
		return mt[key]
	end
	return nil
end

local BindCasterEventSignal

local function NewIndexCaster(self, key, value)
	if SIGNAL_EVENT_TYPES[key] then
		local events = rawget(self, "_events")
		if not events then
			events = NewCasterSignals()
			rawset(self, "_events", events)
		end

		if type(value) == "function" then
			-- Backwards compatible assignment: connect the function, replacing
			-- any previous function assigned this way.
			local legacy = rawget(self, "_legacy")
			if not legacy then
				legacy = {}
				rawset(self, "_legacy", legacy)
			end

			local previous = legacy[key]
			if previous then
				previous:Disconnect()
			end

			legacy[key] = events[key]:Connect(value)
		elseif Signal.is(value) then
			local previousSignal = events[key]
			if Signal.is(previousSignal) and previousSignal ~= value then
				previousSignal:SetListenerFlagChanged(nil)
			end

			local legacy = rawget(self, "_legacy")
			if legacy and legacy[key] then
				legacy[key]:Disconnect()
				legacy[key] = nil
			end

			events[key] = value
			BindCasterEventSignal(self, key, value)
		elseif value == nil then
			local legacy = rawget(self, "_legacy")
			if legacy and legacy[key] then
				legacy[key]:Disconnect()
				legacy[key] = nil
			end
		else
			warn("[FastCast2] Cannot set event '" .. tostring(key) .. "', expected a function or Signal")
		end
		return
	end

	if QUERY_EVENTS[key] then
		if value == nil or type(value) == "function" then
			rawset(self, key, value)
		else
			warn("[FastCast2] Cannot set CanPierce, expected a function")
		end
		return
	end

	rawset(self, key, value)
end

local CasterRegistry: { [number]: any } = {}
local NextCasterId = 0
local RuntimeInitialized = false
local ParallelSimulationRunning = false
local RuntimeDestroying = false
local RuntimeMovementMode: "BulkMoveTo" | "Motor6D" = "BulkMoveTo"
local DefaultFastCastEventsModule: ModuleScript? = nil
local DestroyingCasters: { [number]: { caster: any, remaining: number } } = {}
local ParallelDispatcher = nil

BindCasterEventSignal = function(caster, eventName: string, signal)
	local eventType = SIGNAL_EVENT_TYPES[eventName]
	signal:SetListenerFlagChanged(function(hasListeners: boolean)
		if rawget(caster, "_destroying") then
			return
		end

		local events = rawget(caster, "_events")
		if not events or events[eventName] ~= signal then
			return
		end

		local eventFlags = rawget(caster, "_eventFlags")
		if eventFlags[eventType] == hasListeners then
			return
		end

		eventFlags[eventType] = hasListeners
		if RuntimeInitialized and not RuntimeDestroying and ParallelDispatcher then
			ParallelDispatcher:DispatchAll("SetCasterEvents", caster.CasterId, table.clone(eventFlags))
		end
	end)
end

local function BindCasterEventSignals(caster)
	local events = rawget(caster, "_events")
	for eventName in SIGNAL_EVENT_TYPES do
		local signal = events[eventName]
		if Signal.is(signal) then
			BindCasterEventSignal(caster, eventName, signal)
		end
	end
end

-- Demux worker event batches by numeric CasterId instead of binding the
-- shared worker pool to a single caster.
local function DispatchOutputBatch(batch)
	for i = 1, #batch do
		local record = batch[i]
		local signalName = OUTPUT_EVENT_NAMES[record[1]]
		local cast = record[2]
		local caster = cast and CasterRegistry[cast.CasterId]

		if signalName and caster then
			local signal = caster[signalName]
			if Signal.is(signal) then
				local argCount = record[4]
				if argCount > 0 then
					signal:Fire(cast, table.unpack(record[3], 1, argCount))
				else
					signal:Fire(cast)
				end
			end
		end
	end
end

local function FinalizeDestroyedCaster(casterId: number)
	local state = DestroyingCasters[casterId]
	if not state then
		return
	end

	local caster = state.caster
	DestroyingCasters[casterId] = nil
	CasterRegistry[casterId] = nil
	DestroyCasterSignals(caster)
	rawset(caster, "CasterId", nil)
	rawset(caster, "FastCastEventsModule", nil)
	rawset(caster, "_destroying", nil)
	setmetatable(caster, nil)
	rawset(caster, "Destroy", function() end)
end

local function HandleCasterDestroyed(casterId: number)
	local state = DestroyingCasters[casterId]
	if not state then
		return
	end

	state.remaining -= 1
	if state.remaining <= 0 then
		FinalizeDestroyedCaster(casterId)
	end
end

--[=[
	@class FastCast

	FastCast provides static utility methods for manipulating active casts (velocity, position, acceleration)
	and serves as the module root for constructing parallel casters.
]=]

local FastCast = {}
FastCast.HighFidelityBehavior = {
	Default = 1,
	Automatic = 2,
	Always = 3
}
FastCast.CastType = {
	Raycast = 1,
	Blockcast = 2,
	Spherecast = 3
}
--[=[
	@class FastCastParallel

	FastCastParallel is the parallel caster class that runs cast simulations on separate worker VMs.
]=]
local FastCastParallel = {}

--[[
If true, verbose debug logging will be used, 
	printing detailed information about what's going on during processing to the output.
]]

FastCastParallel.__index = IndexCaster
FastCastParallel.__newindex = NewIndexCaster
FastCastParallel.__type = "FastCastParallel"

-- Local functions

local function GetPositionAtTime(
	time: number,
	origin: Vector3,
	initialVelocity: Vector3,
	acceleration: Vector3
): Vector3
	local force =
		Vector3.new((acceleration.X * time ^ 2) / 2, (acceleration.Y * time ^ 2) / 2, (acceleration.Z * time ^ 2) / 2)
	return origin + (initialVelocity * time) + force
end

local function GetVelocityAtTime(time: number, initialVelocity: Vector3, acceleration: Vector3): Vector3
	return initialVelocity + acceleration * time
end

--[[
local function GetTrajectoryInfo(
	cast: vaildcast,
	index: number
): { [number]: Vector3 }
	local trajectory = cast.StateInfo.Trajectory
	local duration = trajectory.EndTime ~= -1
		and (trajectory.EndTime - trajectory.StartTime)
		or (cast.StateInfo.TotalRuntime - trajectory.StartTime)

	local origin = trajectory.Origin
	local vel = trajectory.InitialVelocity
	local accel = trajectory.Acceleration

	return { GetPositionAtTime(duration, origin, vel, accel), GetVelocityAtTime(duration, vel, accel) }
end
--]]

--[[
local function GetLatestTrajectoryEndInfo(cast: vaildcast): { [number]: Vector3 }
	return GetTrajectoryInfo(cast, 1)
end
--]]

local function ModifyTransformation(
	cast: vaildcast,
	velocity: Vector3?,
	acceleration: Vector3?,
	position: Vector3?
)
	local trajectory = cast.StateInfo.Trajectory

	local t = cast.StateInfo.TotalRuntime - trajectory.StartTime
	local currentPosition = GetPositionAtTime(t, trajectory.Origin, trajectory.InitialVelocity, trajectory.Acceleration)
	local currentVelocity = GetVelocityAtTime(t, trajectory.InitialVelocity, trajectory.Acceleration)

	trajectory.Origin = position or currentPosition
	trajectory.InitialVelocity = velocity or currentVelocity
	trajectory.Acceleration = acceleration or trajectory.Acceleration
	trajectory.StartTime = cast.StateInfo.TotalRuntime
	cast.StateInfo.CancelHighResCast = true
end

local function deepCopyTable(tbl: {any}): {any}
	local newTable = {}
	for i, v in tbl do
		if type(v) == "table" then
			newTable[i] = deepCopyTable(v)
		else
			newTable[i] = v
		end
	end
	return newTable
end

--[=[
	Creates a new FastCastBehavior, which contains information necessary to fire the cast properly.

	@return FastCastBehavior
]=]
function FastCast.newBehavior(): TypeDef.FastCastBehavior
	return deepCopyTable(DefaultConfigs.FastCastBehavior) :: TypeDef.FastCastBehavior
end

--[=[
	Creates a new parallel caster. Cast simulations run on separate worker VMs.
	Initialize the caster before firing projectiles.

	@function new
	@within FastCast
	@return CasterParallel
]=]
function FastCast.new()
	NextCasterId += 1

	local caster = {
		CasterId = NextCasterId,
		_events = NewCasterSignals(),
		_eventFlags = {
		[EventType.CastFire] = false,
		[EventType.OnStep] = false,
		[EventType.CastTerminating] = false,
		[EventType.Hit] = false,
		[EventType.Pierced] = false,
		[EventType.LengthChanged] = false,
		},
		WorldRoot = workspace,
		FastCastEventsModule = DefaultFastCastEventsModule,
	}

	setmetatable(caster, FastCastParallel)
	CasterRegistry[caster.CasterId] = caster
	BindCasterEventSignals(caster)
	return caster
end

-- Batched parallel dispatch. Shots are queued and sent once per frame per
-- worker instead of one message per shot, removing the per-shot cost of
-- crossing the Actor boundary. The behavior is snapshotted when queued so
-- per-shot mutations (such as the raycast filter) are preserved.

local function CloneCastParams(params: RaycastParams): RaycastParams
	local clone = RaycastParams.new()
	clone.CollisionGroup = params.CollisionGroup
	clone.FilterType = params.FilterType
	clone.FilterDescendantsInstances = table.clone(params.FilterDescendantsInstances)
	clone.IgnoreWater = params.IgnoreWater
	clone.RespectCanCollide = params.RespectCanCollide
	return clone
end

local function SnapshotBehavior(behavior: any): any
	local copy = deepCopyTable(behavior)
	if behavior.RaycastParams then
		copy.RaycastParams = CloneCastParams(behavior.RaycastParams)
	end
	return copy
end

local FireQueue = {}
local FireBatches = {}
local FireUsed = {}
local FireFlushConnection: RBXScriptConnection? = nil

local function QueueFire(request: { any })
	FireQueue[#FireQueue + 1] = request
end

local function FlushFires()
	local count = #FireQueue
	if count == 0 then
		return
	end

	local dispatcher = ParallelDispatcher
	local threads = dispatcher and dispatcher.Threads
	local workerCount = if threads then #threads else 0

	if workerCount == 0 then
		table.clear(FireQueue)
		return
	end

	local usedCount = 0

	for i = 1, count do
		local worker = (i - 1) % workerCount + 1
		local batch = FireBatches[worker]

		if not batch then
			batch = {}
			FireBatches[worker] = batch
		end

		-- Batches are reused across frames, so register each non-empty batch
		-- for this flush, not only when its backing table is first created.
		if #batch == 0 then
			usedCount += 1
			FireUsed[usedCount] = worker
		end

		batch[#batch + 1] = FireQueue[i]
	end

	table.clear(FireQueue)

	for i = 1, usedCount do
		local worker = FireUsed[i]
		local batch = FireBatches[worker]

		-- Send a snapshot because the worker consumes the message asynchronously.
		-- Do not let reuse of the pooled batch table mutate an in-flight request.
		threads[worker]:SendMessage("FireBatch", table.clone(batch))
		table.clear(batch)
		FireUsed[i] = nil
	end
end

--[=[
	Initialize the shared parallel simulation runtime.
	@method Init
	@within FastCast

	@param numWorkers number -- Number of parallel workers.
	@param movementMode "BulkMoveTo" | "Motor6D"? -- Shared movement mode. Defaults to "BulkMoveTo".
	@param FastCastEventsModule ModuleScript? -- Optional default events module for casters without their own.
]=]
function FastCast.Init(
	numWorkers: number,
	movementMode: "BulkMoveTo" | "Motor6D"?,
	FastCastEventsModule: ModuleScript?
)
	if RuntimeDestroying then
		error("Cannot call FastCast.Init() while FastCast.DestroyVMs() is in progress")
	end

	if RuntimeInitialized then
		local initializedWorkerCount = ParallelDispatcher and #ParallelDispatcher.Threads or 0
		if numWorkers ~= initializedWorkerCount then
			warn("[FastCast2] FastCast.Init() already initialized with "
				.. initializedWorkerCount .. " workers; ignoring the new worker count.")
		end

		if movementMode and movementMode ~= RuntimeMovementMode then
			FastCast.SetMovementModeEnabled(true, movementMode)
		end

		if FastCastEventsModule then
			DefaultFastCastEventsModule = FastCastEventsModule
			for _, caster in CasterRegistry do
				if not caster.FastCastEventsModule then
					caster.FastCastEventsModule = FastCastEventsModule
				end
			end
		end

		if not FireFlushConnection then
			FireFlushConnection = RunService.PreSimulation:Connect(FlushFires)
		end

		if not ParallelSimulationRunning then
			ParallelDispatcher:DispatchAll("StartSimulation")
			ParallelSimulationRunning = true
		end
		return
	end

	assert(type(numWorkers) == "number" and numWorkers >= 1 and numWorkers % 1 == 0,
		"numWorkers must be a positive integer")

	local dispatcherClone = DispatcherModule:Clone()
	dispatcherClone.Parent = PARALLEL_PARENT
	dispatcherClone.Name = DISPATCHER_NAME

	local newDispatcher: Dispatcher.Dispatcher = require(dispatcherClone) :: Dispatcher.Dispatcher
	newDispatcher.Init(PARALLEL_PARENT, VM_CONTAINER_NAME, VM_NAME)

	local data = {
		movementMode = movementMode or "BulkMoveTo",
		FastCastModule = script
	}

	ParallelDispatcher = newDispatcher.new(numWorkers, data, function(eventType: number, ...)
		if eventType == EventType.Batch then
			DispatchOutputBatch(...)
			return
		end

		if eventType == EventType.CasterDestroyed then
			HandleCasterDestroyed(...)
			return
		end

		local cast = select(1, ...)
		local caster = cast and CasterRegistry[cast.CasterId]
		local signalName = OUTPUT_EVENT_NAMES[eventType]
		local signal = signalName and caster and caster[signalName]
		if Signal.is(signal) then
			signal:Fire(...)
		end
	end)

	for casterId, caster in CasterRegistry do
		ParallelDispatcher:DispatchAll("SetCasterEvents", casterId, table.clone(caster._eventFlags))
	end

	RuntimeMovementMode = movementMode or "BulkMoveTo"
	DefaultFastCastEventsModule = FastCastEventsModule
	for _, caster in CasterRegistry do
		if FastCastEventsModule and not caster.FastCastEventsModule then
			caster.FastCastEventsModule = FastCastEventsModule
		end
	end

	if not FireFlushConnection then
		FireFlushConnection = RunService.PreSimulation:Connect(FlushFires)
	end

	ParallelSimulationRunning = true
	RuntimeInitialized = true
end

--[=[
	Stop simulation updates while preserving active casts and the worker pool.
	Call FastCast.Init() again to resume the existing runtime.

	@method Stop
	@within FastCast
]=]
function FastCast.Stop()
	if RuntimeDestroying or not RuntimeInitialized or not ParallelSimulationRunning then
		return
	end

	if FireFlushConnection then
		FireFlushConnection:Disconnect()
		FireFlushConnection = nil
	end

	ParallelDispatcher:DispatchAll("StopSimulation")
	ParallelSimulationRunning = false
end

--[=[
	Destroy the shared worker VMs and tear down the initialized runtime.
	Active casts are discarded with the workers. Existing caster objects and
	their event signals remain available, but Init() must be called again before
	firing more casts.
	@method DestroyVMs
	@within FastCast
]=]
function FastCast.DestroyVMs()
	if not RuntimeInitialized or RuntimeDestroying then
		return
	end

	RuntimeDestroying = true

	local dispatcher = ParallelDispatcher
	if FireFlushConnection then
		FireFlushConnection:Disconnect()
		FireFlushConnection = nil
	end

	-- Prevent new requests from being queued while the worker pool is removed.
	table.clear(FireQueue)
	table.clear(FireBatches)
	table.clear(FireUsed)

	if dispatcher then
		-- Stop first so a worker cannot advance casts while its teardown message
		-- is being processed. Destroy() waits until all worker Actors are gone.
		dispatcher:DispatchAll("StopSimulation")
	end

	ParallelSimulationRunning = false
	RuntimeInitialized = false
	ParallelDispatcher = nil

	local ok, err = pcall(function()
		if dispatcher then
			dispatcher:Destroy(true)
		end
	end)

	-- Worker destruction also invalidates any pending per-caster destruction
	-- acknowledgements; finalize those casters now that no worker can reply.
	local pendingCasterIds = {}
	for casterId in DestroyingCasters do
		table.insert(pendingCasterIds, casterId)
	end
	for _, casterId in pendingCasterIds do
		FinalizeDestroyedCaster(casterId)
	end

	RuntimeMovementMode = "BulkMoveTo"
	RuntimeDestroying = false

	if not ok then
		error("FastCast.DestroyVMs() failed to tear down the worker pool: " .. tostring(err), 2)
	end
end

--[=[
	Set the FastCastEventsModule used by casts fired from this caster.
	
	@method SetFastCastEventsModule
	@within FastCastParallel
	
	@param moduleScript ModuleScript? -- The FastCastEventsModule to set, or nil to disable it.
]=]
function FastCastParallel:SetFastCastEventsModule(moduleScript: ModuleScript?)
	if moduleScript ~= nil
		and (typeof(moduleScript) ~= "Instance" or not moduleScript:IsA("ModuleScript"))
	then
		error("FastCastEventsModule must be a ModuleScript")
	end
	if not self.CasterId or self._destroying then
		error("This caster has been destroyed")
	end

	-- The module travels with each cast request, allowing separate casters to
	-- use different event modules on the shared worker pool.
	self.FastCastEventsModule = moduleScript
end

--[=[
	Raycasts the Caster with the specified parameters.
	@method RaycastFire
	@within FastCastParallel

	@param origin Vector3 -- The origin of the raycast.
	@param direction Vector3 -- The direction of the raycast.
	@param velocity Vector3 | number -- The velocity of the raycast.
	@param BehaviorData FastCastBehavior? -- The behavior data for the raycast.
]=]
function FastCastParallel:RaycastFire(
	origin: Vector3,
	direction: Vector3,
	velocity: Vector3 | number,
	BehaviorData: TypeDef.FastCastBehavior?
)
	if RuntimeDestroying then
		error("Cannot fire casts while FastCast.DestroyVMs() is in progress")
	end
	if not RuntimeInitialized then
		error("Please call FastCast.Init() before firing casts")
	end
	if not self.CasterId or self._destroying then
		error("This caster has been destroyed")
	end
	if BehaviorData == nil then
		BehaviorData = FastCast.newBehavior()
	end

	QueueFire({
		1,
		self.CasterId,
		origin,
		direction,
		velocity,
		SnapshotBehavior(BehaviorData),
		self.FastCastEventsModule
	})
end

--[=[
	Blockcasts the Caster with the specified parameters.
	@method BlockcastFire
	@within FastCastParallel

	@param origin Vector3 -- The origin of the blockcast.
	@param Size Vector3 -- The size of the blockcast.
	@param direction Vector3 -- The direction of the blockcast.
	@param velocity Vector3 | number -- The velocity of the blockcast.
	@param BehaviorData FastCastBehavior? -- The behavior data for the blockcast.
]=]
function FastCastParallel:BlockcastFire(
	origin: Vector3,
	Size: Vector3,
	direction: Vector3,
	velocity: Vector3 | number,
	BehaviorData: TypeDef.FastCastBehavior?
)
	if RuntimeDestroying then
		error("Cannot fire casts while FastCast.DestroyVMs() is in progress")
	end
	if not RuntimeInitialized then
		error("Please call FastCast.Init() before firing casts")
	end
	if not self.CasterId or self._destroying then
		error("This caster has been destroyed")
	end
	if BehaviorData == nil then
		BehaviorData = FastCast.newBehavior()
	end

	QueueFire({
		2,
		self.CasterId,
		origin,
		Size,
		direction,
		velocity,
		SnapshotBehavior(BehaviorData),
		self.FastCastEventsModule
	})
end

--[=[
	Spherecasts the Caster with the specified parameters.
	@method SpherecastFire
	@within FastCastParallel

	@param origin Vector3 -- The origin of the spherecast.
	@param Radius number -- The radius of the spherecast.
	@param direction Vector3 -- The direction of the spherecast.
	@param velocity Vector3 | number -- The velocity of the spherecast.
	@param BehaviorData FastCastBehavior? -- The behavior data for the spherecast.
]=]
function FastCastParallel:SpherecastFire(
	origin: Vector3,
	Radius: number,
	direction: Vector3,
	velocity: Vector3 | number,
	BehaviorData: TypeDef.FastCastBehavior?
)
	if RuntimeDestroying then
		error("Cannot fire casts while FastCast.DestroyVMs() is in progress")
	end
	if not RuntimeInitialized then
		error("Please call FastCast.Init() before firing casts")
	end
	if not self.CasterId or self._destroying then
		error("This caster has been destroyed")
	end
	if BehaviorData == nil then
		BehaviorData = FastCast.newBehavior()
	end

	QueueFire({
		3,
		self.CasterId,
		origin,
		Radius,
		direction,
		velocity,
		SnapshotBehavior(BehaviorData),
		self.FastCastEventsModule
	})
end

--[=[
	Sets the movement mode for casts.

	@method SetMovementModeEnabled
	@param enabled boolean -- Is enabled
	@param mode "BulkMoveTo" | "Motor6D" -- The movement mode to set for casts.
	@within FastCast
]=]
function FastCast.SetMovementModeEnabled(enabled: boolean, mode: "BulkMoveTo" | "Motor6D")
	if not RuntimeInitialized or not ParallelDispatcher then
		return
	end

	ParallelDispatcher:DispatchAll("SetMovementModeEnabled", enabled, mode)
	RuntimeMovementMode = mode
end

function FastCastParallel:Destroy()
	if getmetatable(self) ~= FastCastParallel then
		return
	end

	local casterId = self.CasterId
	if not casterId or self._destroying then
		return
	end
	self._destroying = true

	-- Drop queued (not-yet-dispatched) requests for only this caster.
	local writeIndex = 1
	for readIndex = 1, #FireQueue do
		local request = FireQueue[readIndex]
		if request[2] ~= casterId then
			FireQueue[writeIndex] = request
			writeIndex += 1
		end
	end
	for index = writeIndex, #FireQueue do
		FireQueue[index] = nil
	end

	if not RuntimeInitialized or not ParallelDispatcher then
		CasterRegistry[casterId] = nil
		DestroyCasterSignals(self)
		rawset(self, "CasterId", nil)
		rawset(self, "FastCastEventsModule", nil)
		setmetatable(self, nil)
		rawset(self, "Destroy", function() end)
		return
	end

	DestroyingCasters[casterId] = {
		caster = self,
		remaining = #ParallelDispatcher.Threads
	}
	ParallelDispatcher:DispatchAll("DestroyCaster", casterId)
end

-- Utility Methods

--[=[

Gets the velocity of an ActiveCast.

	@method GetVelocityCast
	@param cast vaildcast -- The active cast to get the velocity of.
	@within FastCast
	@return Vector3 -- The current velocity of the ActiveCast.
]=]
function FastCast.GetVelocityCast(cast: vaildcast)
	local currentTrajectory = cast.StateInfo.Trajectory
	return GetVelocityAtTime(
		cast.StateInfo.TotalRuntime - currentTrajectory.StartTime,
		currentTrajectory.InitialVelocity,
		currentTrajectory.Acceleration
	)
end

--[=[

Gets the acceleration of an ActiveCast.

	@method GetAccelerationCast
	@param cast vaildcast -- The active cast to get the acceleration of.
	@within FastCast
	@return Vector3 -- The current acceleration of the ActiveCast.

]=]
function FastCast.GetAccelerationCast(cast: vaildcast)
	return cast.StateInfo.Trajectory.Acceleration
end

--[=[

Gets the position of an ActiveCast.

	@method GetPositionCast
	@param cast vaildcast -- The active cast to get the position of.
	@within FastCast
	@return Vector3 -- The current position of the ActiveCast.
]=]
function FastCast.GetPositionCast(cast: vaildcast)
	local currentTrajectory = cast.StateInfo.Trajectory
	return GetPositionAtTime(
		cast.StateInfo.TotalRuntime - currentTrajectory.StartTime,
		currentTrajectory.Origin,
		currentTrajectory.InitialVelocity,
		currentTrajectory.Acceleration
	)
end

--[=[

Sets the velocity of an ActiveCast to the specified Vector3.

	@method SetVelocityCast
	@param cast vaildcast -- The active cast to modify.
	@param velocity Vector3 -- The new velocity to set.
	@within FastCast

]=]
function FastCast.SetVelocityCast(cast: vaildcast, velocity: Vector3)
	ModifyTransformation(cast, velocity, nil, nil)
end

--[=[

Sets the acceleration of an ActiveCast to the specified Vector3.

	@method SetAccelerationCast
	@param cast vaildcast -- The active cast to modify.
	@param acceleration Vector3 -- The new acceleration to set.
	@within FastCast

]=]
function FastCast.SetAccelerationCast(cast: vaildcast, acceleration: Vector3)
	ModifyTransformation(cast, nil, acceleration, nil)
end

--[=[
	Sets the position of an ActiveCast to the specified Vector3.

	@method SetPositionCast
	@param cast vaildcast -- The active cast to modify.
	@param position Vector3 -- The new position to set.
	@within FastCast
]=]
function FastCast.SetPositionCast(cast: vaildcast, position: Vector3)
	ModifyTransformation(cast, nil, nil, position)
end

--[=[

Add position to an ActiveCast with the specified Vector3.

	@method AddPositionCast
	@param cast vaildcast -- The active cast to modify.
	@param position Vector3 -- The new position to add.
	@within FastCast

]=]
function FastCast.AddPositionCast(cast: vaildcast, position: Vector3)
	FastCast.SetPositionCast(cast, FastCast.GetPositionCast(cast) + position)
end

--[=[

Add velocity to an ActiveCast with the specified Vector3.

	@method AddVelocityCast
	@param cast vaildcast -- The active cast to modify.
	@param velocity Vector3 -- The new velocity to add.
	@within FastCast

]=]
function FastCast.AddVelocityCast(cast: vaildcast, velocity: Vector3)
	FastCast.SetVelocityCast(cast, FastCast.GetVelocityCast(cast) + velocity)
end

--[=[

Add acceleration to an ActiveCast with the specified Vector3.

	@method AddAccelerationCast
	@param cast vaildcast -- The active cast to modify.
	@param acceleration Vector3 -- The new acceleration to add.
	@within FastCast

]=]
function FastCast.AddAccelerationCast(cast: vaildcast, acceleration: Vector3)
	FastCast.SetAccelerationCast(cast, FastCast.GetAccelerationCast(cast) + acceleration)
end

--[=[
	Sets a cast's velocity while preserving its current position and runtime.
	In parallel mode, call FastCast:SyncChangesToCast(cast) after changing trajectory.
	@method SetVelocity
	@within FastCast
]=]
function FastCast.SetVelocity(cast: vaildcast, velocity: Vector3)
	FastCast.SetVelocityCast(cast, velocity)
end

--[=[
	Sets a cast's acceleration while preserving its current position and runtime.
	In parallel mode, call FastCast:SyncChangesToCast(cast) after changing trajectory.
	@method SetAcceleration
	@within FastCast
]=]
function FastCast.SetAcceleration(cast: vaildcast, acceleration: Vector3)
	FastCast.SetAccelerationCast(cast, acceleration)
end

-- Route pause changes directly to the worker that owns the cast. The public
-- cast passed to callbacks is a cross-VM snapshot, so don't rely on its
-- embedded BindableEvent to synchronize the worker's live state.
local function SyncPausedState(cast: any)
	local baseCast = cast.Caster
	local actor = baseCast and baseCast.Actor
	if actor then
		actor:SendMessage("SetCastPaused", cast.ID, cast.StateInfo.IsPaused)
		return
	end

	-- Retain a fallback for cast objects without an Actor reference.
	local syncChange = baseCast and baseCast.SyncChange
	if syncChange then
		syncChange:Fire(cast, false, true)
	end
end

--[=[
	Pauses an active parallel cast without advancing simulation time.
	@method PauseCast
	@within FastCast
]=]
function FastCast.PauseCast(cast: any)
	if not cast or not cast.StateInfo or cast._Destroying or cast._TerminationQueued then
		return
	end

	cast.StateInfo.IsPaused = true
	SyncPausedState(cast)
end

--[=[
	Resumes a cast paused with PauseCast.
	@method ResumeCast
	@within FastCast
]=]
function FastCast.ResumeCast(cast: any)
	if not cast or not cast.StateInfo or cast._Destroying or cast._TerminationQueued then
		return
	end

	cast.StateInfo.IsPaused = false
	SyncPausedState(cast)
end

--[=[

Synchronize new changes to the ActiveCast.

	@method SyncChangesToCast
	@param cast vaildcast -- The active cast to synchronize.
	@within FastCast

]=]
function FastCast:SyncChangesToCast(cast: vaildcast)
	local syncChange: BindableEvent = (cast.Caster :: any).SyncChange
	local cancelHighResCast = cast.StateInfo.CancelHighResCast

	-- Send the high-fidelity cancellation as a separate value so the worker
	-- can apply it to its simulation cache. This field is a one-shot request.
	cast.StateInfo.CancelHighResCast = false
	syncChange:Fire(cast, cancelHighResCast)
end

--[=[
	Terminate function for casts
	@method TerminateCast
	@param cast vaildcast -- The active cast to terminate.
	@param castTerminatingFunction (cast: vaildcast) -> ())? -- Optional callback invoked just before the cast is terminated.
	@within FastCast

	Note: If EndTime is already set, the cast is already terminated and this function returns early.
]=]
function FastCast.TerminateCast(cast: vaildcast)
	if cast._Destroying or cast._TerminationQueued then
		return
	end

	local caster = cast.Caster
	if caster == nil then
		return
	end

	cast._Destroying = true

	local publicCaster = CasterRegistry[cast.CasterId]
	if publicCaster and publicCaster._eventFlags[EventType.CastTerminating] then
		caster.Output:Fire(EventType.CastTerminating, cast)
	end

	caster.Actor:SendMessage("Cleanup", cast.ID)
end

-- Constructors

return FastCast
