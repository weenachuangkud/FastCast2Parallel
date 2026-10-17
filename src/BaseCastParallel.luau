--[[
	- Author : Mawin CK
	- Date : 2025

]]

local FastCast2 = script.Parent

local FastCastEnums = require(FastCast2:WaitForChild("FastCastEnums"))
local ActiveCast = require(FastCast2:WaitForChild("ActiveCast"))
local TypeDef = require(FastCast2:WaitForChild("TypeDefinitions"))
local ParallelSimulation = require(FastCast2:WaitForChild("ParallelSimulation"))
local Motor6DCache = require(FastCast2:WaitForChild("Motor6DCache"))

local EnumCastTypes = FastCastEnums.CastType

local BaseCast = {}
BaseCast.__index = BaseCast
BaseCast.__type = "BaseCast"

local Actor = nil
local Output = nil
local Motor6DCacheInstance: any = nil
local NextProjectileID = 0
local SyncChanges: BindableEvent = nil
local SyncChangesConnection: RBXScriptConnection? = nil
local CurrentMovementMode: "BulkMoveTo" | "Motor6D" = "BulkMoveTo"

local function SendCastFire(
	cast: TypeDef.ActiveCastData,
	origin: Vector3,
	direction: Vector3,
	velocity: Vector3 | number,
	behavior: TypeDef.FastCastBehavior
)
	(cast.Caster :: any).Output:Fire("CastFire", cast, origin, direction, velocity, behavior)
end

local function TerminateCast(cast: any, castTerminatingFunction: TypeDef.OnCastTerminatingFunction?)
	if cast._Destroying then return end
	cast._Destroying = true

	local FastCastEventsConfig = cast.StateInfo.FastCastEventsConfig
	if FastCastEventsConfig and FastCastEventsConfig.UseCastTerminating then
		cast.Caster.Output:Fire("CastTerminating", cast)
	end

	if castTerminatingFunction then
		castTerminatingFunction((cast :: any))
	end
	
	table.clear(cast :: any)
end

-- These values are updated by the worker and must never be copied from
-- the caller's potentially stale cast snapshot.
local WorkerOwnedStateFields = {
	TotalRuntime = true,
	DistanceCovered = true,
	IsActivelySimulatingPierce = true,
	IsActivelyResimulating = true,
}

local PreservedCastFields = {
	Caster = true,
	CasterId = true,
	ID = true,
	Mode = true,
	_Destroying = true,
	_TerminationQueued = true,
	StateInfo = true,
	RayInfo = true,
	CastVariant = true,
	Type = true,
	UserData = true,
	CFrame = true,
}

-- Preserve the trajectory table because ParallelSimulation caches its reference.
local function SyncTrajectoryChanges(sourceTrajectory: any, targetTrajectory: any): boolean
	local changed = false

	for key in targetTrajectory do
		if sourceTrajectory[key] == nil then
			targetTrajectory[key] = nil
			changed = true
		elseif sourceTrajectory[key] ~= targetTrajectory[key] then
			changed = true
		end
	end

	for key, value in sourceTrajectory do
		if targetTrajectory[key] ~= value then
			changed = true
			targetTrajectory[key] = value
		end
	end

	return changed
end

local function SyncCastData(sourceCast: any, targetCast: any)
	local sourceState = sourceCast.StateInfo
	local targetState = targetCast.StateInfo
	local targetTrajectory = targetState.Trajectory
	local targetRayInfo = targetCast.RayInfo
	local sourceRayInfo = sourceCast.RayInfo
	local oldCastType = targetCast.Type
	local oldVariant = targetCast.CastVariant
	local oldVariantType = oldVariant.CastType
	local oldVariantSize = oldVariant.Size
	local oldVariantRadius = oldVariant.Radius
	local oldRayInfoSize = targetRayInfo.Size
	local oldRayInfoRadius = targetRayInfo.Radius
	local oldParameters = targetRayInfo.Parameters
	local oldWorldRoot = targetRayInfo.WorldRoot
	local oldMaxDistance = targetRayInfo.MaxDistance
	local oldHighFidelityBehavior = targetState.HighFidelityBehavior
	local oldHighFidelitySegmentSize = targetState.HighFidelitySegmentSize
	local trajectoryChanged = false

	-- Copy every state field except values owned by the simulation worker.
	for key in targetState do
		if not WorkerOwnedStateFields[key]
			and key ~= "Trajectory"
			and sourceState[key] == nil
		then
			targetState[key] = nil
		end
	end

	for key, value in sourceState do
		if not WorkerOwnedStateFields[key] then
			if key == "Trajectory" then
				trajectoryChanged = SyncTrajectoryChanges(value, targetTrajectory)
			else
				targetState[key] = value
			end
		end
	end

	targetState.Trajectory = targetTrajectory

	-- Keep RayInfo's table identity because the simulation caches its reference.
	for key in targetRayInfo do
		if sourceRayInfo[key] == nil then
			targetRayInfo[key] = nil
		end
	end

	for key, value in sourceRayInfo do
		targetRayInfo[key] = value
	end

	-- Copy custom cast-level fields without replacing identity or worker-owned data.
	for key in targetCast do
		if not PreservedCastFields[key] and sourceCast[key] == nil then
			targetCast[key] = nil
		end
	end

	for key, value in sourceCast do
		if not PreservedCastFields[key] then
			targetCast[key] = value
		end
	end

	targetCast.UserData = sourceCast.UserData

	-- CastVariant determines which shape the worker simulates. Accept shape-size
	-- edits through either RayInfo or CastVariant, then keep both representations
	-- consistent for the selected cast type.
	local sourceVariant = sourceCast.CastVariant
	local castType = sourceVariant.CastType
	if sourceCast.Type ~= oldCastType then
		castType = sourceCast.Type
	elseif sourceVariant.CastType ~= oldVariantType then
		castType = sourceVariant.CastType
	end

	local variant = table.clone(sourceVariant)
	variant.CastType = castType

	if castType == EnumCastTypes.Blockcast then
		local size = sourceRayInfo.Size
		if size == oldRayInfoSize and sourceVariant.Size ~= oldVariantSize then
			size = sourceVariant.Size
		end
		size = size or sourceVariant.Size or Vector3.one

		variant.Size = size
		variant.Radius = nil
		targetRayInfo.Size = size
		targetRayInfo.Radius = nil
		targetCast.Type = EnumCastTypes.Blockcast
	elseif castType == EnumCastTypes.Spherecast then
		local radius = sourceRayInfo.Radius
		if radius == oldRayInfoRadius and sourceVariant.Radius ~= oldVariantRadius then
			radius = sourceVariant.Radius
		end
		radius = radius or sourceVariant.Radius or 0.5

		variant.Radius = radius
		variant.Size = nil
		targetRayInfo.Radius = radius
		targetRayInfo.Size = nil
		targetCast.Type = EnumCastTypes.Spherecast
	else
		variant.Size = nil
		variant.Radius = nil
		targetRayInfo.Size = nil
		targetRayInfo.Radius = nil
		targetCast.Type = EnumCastTypes.Raycast
	end

	targetCast.CastVariant = variant

	return trajectoryChanged
		or oldCastType ~= castType
		or oldVariantSize ~= variant.Size
		or oldVariantRadius ~= variant.Radius
		or oldParameters ~= targetRayInfo.Parameters
		or oldWorldRoot ~= targetRayInfo.WorldRoot
		or oldMaxDistance ~= targetRayInfo.MaxDistance
		or oldHighFidelityBehavior ~= targetState.HighFidelityBehavior
		or oldHighFidelitySegmentSize ~= targetState.HighFidelitySegmentSize
end

local BaseCastInitialized = false
local BaseCastInstance = nil
function BaseCast.Init(BindableOutput: BindableEvent, Data: any)
	if BaseCastInitialized then
		return BaseCastInstance
	end
	BaseCastInitialized = true

	local self = setmetatable({}, BaseCast)
	Actor = BindableOutput.Parent
	self.Actives = {}
	self.Actor = Actor
	Output = BindableOutput
	self.Output = BindableOutput

	Actor:SetAttribute("FastCast2Ready", true)

	CurrentMovementMode = Data.movementMode or "BulkMoveTo"
	if CurrentMovementMode == "Motor6D" then
		Motor6DCacheInstance = Motor6DCache.new()
	end

	Actor:BindToMessage("Cleanup", function(activeCastID: number)
		if self.Actives[activeCastID] then
			self.Actives[activeCastID] = nil
			ParallelSimulation.Unregister(activeCastID)
		end
	end)

	SyncChanges = Instance.new("BindableEvent")
	SyncChanges.Name = "SyncChanges"
	SyncChanges.Parent = Actor
	self.SyncChange = SyncChanges

	SyncChangesConnection = SyncChanges.Event:Connect(function(
		cast: TypeDef.ActiveCastData,
		cancelHighResCast: boolean?,
		stateOnly: boolean?
	)
		local ID = cast.ID
		local TargetCast = self.Actives[ID]
		if TargetCast then
			if stateOnly then
				-- Pause/resume must not overwrite worker-owned runtime, distance,
				-- trajectory, or UserData with an older event snapshot.
				if TargetCast.StateInfo and cast.StateInfo then
					TargetCast.StateInfo.IsPaused = cast.StateInfo.IsPaused
				end
			else
				local previousCosmetic = TargetCast.RayInfo.CosmeticBulletObject
				local cancelResimulation = SyncCastData(cast, TargetCast)
				ParallelSimulation.SyncCast(TargetCast, previousCosmetic)

				if cancelHighResCast or cancelResimulation then
					ParallelSimulation.CancelHighResCast(ID)
				end
			end

			if cancelHighResCast then
				ParallelSimulation.CancelHighResCast(ID)
			end
		end
	end)

	ParallelSimulation.Init(self)
	ParallelSimulation.SetMovementModeEnabled(true, CurrentMovementMode)
	ParallelSimulation.Start()

	BaseCastInstance = self
	return self
end

function BaseCast:Raycast(casterId: number, Origin: Vector3, Direction: Vector3, Velocity: Vector3 | number, Behavior: TypeDef.FastCastBehavior, eventModule: ModuleScript?)
	NextProjectileID += 1
	local cast = ActiveCast.createCastData({
		Output = Output,
		Actor = Actor,
		SyncChange = SyncChanges,
		CacheHolder = self.CacheHolder
	}, NextProjectileID, Origin, Direction, Velocity, Behavior, eventModule, {
		CastType = EnumCastTypes.Raycast
	} :: any, true)
	cast.CasterId = casterId
	ParallelSimulation.Register(cast)
	self.Actives[cast.ID] = cast
	if Behavior.FastCastEventsConfig.UseCastFire then
		SendCastFire(cast, Origin, Direction, Velocity, Behavior)
	end
	if Behavior.FastCastEventsModuleConfig
		and Behavior.FastCastEventsModuleConfig.UseCastFire
		and eventModule
	then
		local moduleEvents = require(eventModule)
		local castFire = type(moduleEvents) == "table" and moduleEvents.CastFire or nil
		if type(castFire) == "function" then
			castFire(cast, Origin, Direction, Velocity, Behavior)
		end
	end
end

function BaseCast:Blockcast(casterId: number, Origin: Vector3, Size: Vector3, Direction: Vector3, Velocity: Vector3 | number, Behavior: TypeDef.FastCastBehavior, eventModule: ModuleScript?)
	NextProjectileID += 1
	local cast = ActiveCast.createCastData({
		Output = Output,
		Actor = Actor,
		SyncChange = SyncChanges,
		CacheHolder = self.CacheHolder
	}, NextProjectileID, Origin, Direction, Velocity, Behavior, eventModule, {
		CastType = EnumCastTypes.Blockcast,
		Size = Size
	} :: any, true)
	cast.CasterId = casterId
	ParallelSimulation.Register(cast)
	self.Actives[cast.ID] = cast
	if Behavior.FastCastEventsConfig.UseCastFire then
		SendCastFire(cast, Origin, Direction, Velocity, Behavior)
	end
	if Behavior.FastCastEventsModuleConfig
		and Behavior.FastCastEventsModuleConfig.UseCastFire
		and eventModule
	then
		local moduleEvents = require(eventModule)
		local castFire = type(moduleEvents) == "table" and moduleEvents.CastFire or nil
		if type(castFire) == "function" then
			castFire(cast, Origin, Direction, Velocity, Behavior)
		end
	end
end

function BaseCast:Spherecast(casterId: number, Origin: Vector3, Radius: number, Direction: Vector3, Velocity: Vector3 | number, Behavior: TypeDef.FastCastBehavior, eventModule: ModuleScript?)
	NextProjectileID += 1
	local cast = ActiveCast.createCastData({
		Output = Output,
		Actor = Actor,
		SyncChange = SyncChanges,
		CacheHolder = self.CacheHolder
	}, NextProjectileID, Origin, Direction, Velocity, Behavior, eventModule, {
		CastType = EnumCastTypes.Spherecast,
		Radius = Radius
	} :: any, true)
	cast.CasterId = casterId
	ParallelSimulation.Register(cast)
	self.Actives[cast.ID] = cast
	if Behavior.FastCastEventsConfig.UseCastFire then
		SendCastFire(cast, Origin, Direction, Velocity, Behavior)
	end
	if Behavior.FastCastEventsModuleConfig
		and Behavior.FastCastEventsModuleConfig.UseCastFire
		and eventModule
	then
		local moduleEvents = require(eventModule)
		local castFire = type(moduleEvents) == "table" and moduleEvents.CastFire or nil
		if type(castFire) == "function" then
			castFire(cast, Origin, Direction, Velocity, Behavior)
		end
	end
end

function BaseCast:SetMovementModeEnabled(enabled: boolean, mode: "BulkMoveTo" | "Motor6D")
	CurrentMovementMode = mode
	if mode == "Motor6D" and enabled then
		if not Motor6DCacheInstance then Motor6DCacheInstance = Motor6DCache.new() end
	else
		if Motor6DCacheInstance then Motor6DCacheInstance:Destroy(); Motor6DCacheInstance = nil end
	end
	ParallelSimulation.SetMovementModeEnabled(enabled, mode)
end

function BaseCast:DestroyCaster(casterId: number)
	local castIDs = {}
	for castID, cast in self.Actives do
		if cast.CasterId == casterId then
			table.insert(castIDs, castID)
		end
	end

	for _, castID in castIDs do
		local cast = self.Actives[castID]
		if cast then
			TerminateCast(cast)
			self.Actives[castID] = nil
			ParallelSimulation.Unregister(castID)
		end
	end

	Output:Fire("CasterDestroyed", casterId)
end

function BaseCast:Destroy()
	if ParallelSimulation then ParallelSimulation.Stop() end
	if Motor6DCacheInstance then Motor6DCacheInstance:Destroy() end
	if SyncChangesConnection then SyncChangesConnection:Disconnect(); SyncChangesConnection = nil end
	
	local activeList = {}
	for _, v in self.Actives do
		table.insert(activeList, v)
	end

	for _, v in activeList do
		local castID = v.ID
	
		TerminateCast(v)
		self.Actives[castID] = nil
		ParallelSimulation.Unregister(castID)
	end

	self.Actives = {}
	setmetatable(self, nil)
end

function BaseCast:_GetMotor6D(projectilePart: BasePart?)
	if Motor6DCacheInstance and projectilePart then return Motor6DCacheInstance:Connect(projectilePart) end
	return nil
end

function BaseCast:_ReturnMotor6D(motor6d: Motor6D?)
	if Motor6DCacheInstance then Motor6DCacheInstance:Disconnect(motor6d) end
end

return BaseCast
