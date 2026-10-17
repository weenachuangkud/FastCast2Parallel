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

-- The worker owns runtime bookkeeping. SyncChangesToCast must not replace
-- these values with an older snapshot from the caller.
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

local PreservedStateFields = table.clone(WorkerOwnedStateFields)
PreservedStateFields.Trajectory = true

local PreservedShapeFields = {
	Size = true,
	Radius = true,
}

local function NormalizeCastType(castType: any, fallback: number): number
	if castType == "Raycast" then
		return EnumCastTypes.Raycast
	elseif castType == "Blockcast" then
		return EnumCastTypes.Blockcast
	elseif castType == "Spherecast" then
		return EnumCastTypes.Spherecast
	elseif castType == EnumCastTypes.Raycast
		or castType == EnumCastTypes.Blockcast
		or castType == EnumCastTypes.Spherecast
	then
		return castType
	end

	return fallback
end

-- Copy mutable fields while retaining table identity and excluded worker data.
local function SyncFields(source: any, target: any, preservedFields: any?): boolean
	local changed = false

	for key in target do
		if (not preservedFields or not preservedFields[key]) and source[key] == nil then
			target[key] = nil
			changed = true
		end
	end

	for key, value in source do
		if (not preservedFields or not preservedFields[key]) and target[key] ~= value then
			target[key] = value
			changed = true
		end
	end

	return changed
end

local function ResolveCastType(sourceCast: any, targetCast: any): number
	local sourceType = NormalizeCastType(sourceCast.Type, sourceCast.CastVariant.CastType)
	local targetType = NormalizeCastType(targetCast.Type, targetCast.CastVariant.CastType)

	if sourceType ~= targetType then
		return sourceType
	end

	return NormalizeCastType(sourceCast.CastVariant.CastType, sourceType)
end

local function ResolveShapeValue(
	sourceRayInfo: any,
	targetRayInfo: any,
	sourceVariant: any,
	targetVariant: any,
	field: string,
	fallback: any
): any
	local sourceInfoValue = sourceRayInfo[field]
	local sourceVariantValue = sourceVariant[field]

	if sourceInfoValue ~= targetRayInfo[field] then
		return sourceInfoValue
	elseif sourceVariantValue ~= targetVariant[field] then
		return sourceVariantValue
	end

	return sourceInfoValue or sourceVariantValue or fallback
end

local function SyncCastVariant(sourceCast: any, targetCast: any): boolean
	local sourceRayInfo = sourceCast.RayInfo
	local targetRayInfo = targetCast.RayInfo
	local sourceVariant = sourceCast.CastVariant
	local targetVariant = targetCast.CastVariant
	local castType = ResolveCastType(sourceCast, targetCast)
	local variant = table.clone(sourceVariant)
	local changed = targetCast.Type ~= castType or targetVariant.CastType ~= castType

	variant.CastType = castType
	targetCast.Type = castType

	if castType == EnumCastTypes.Blockcast then
		local size = ResolveShapeValue(
			sourceRayInfo,
			targetRayInfo,
			sourceVariant,
			targetVariant,
			"Size",
			Vector3.one
		)
		changed = changed or targetRayInfo.Size ~= size or targetRayInfo.Radius ~= nil
			or targetVariant.Size ~= size or targetVariant.Radius ~= nil

		variant.Size = size
		variant.Radius = nil
		targetRayInfo.Size = size
		targetRayInfo.Radius = nil
	elseif castType == EnumCastTypes.Spherecast then
		local radius = ResolveShapeValue(
			sourceRayInfo,
			targetRayInfo,
			sourceVariant,
			targetVariant,
			"Radius",
			0.5
		)
		changed = changed or targetRayInfo.Radius ~= radius or targetRayInfo.Size ~= nil
			or targetVariant.Radius ~= radius or targetVariant.Size ~= nil

		variant.Radius = radius
		variant.Size = nil
		targetRayInfo.Radius = radius
		targetRayInfo.Size = nil
	else
		changed = changed or targetRayInfo.Size ~= nil or targetRayInfo.Radius ~= nil
			or targetVariant.Size ~= nil or targetVariant.Radius ~= nil

		variant.Size = nil
		variant.Radius = nil
		targetRayInfo.Size = nil
		targetRayInfo.Radius = nil
	end

	targetCast.CastVariant = variant
	return changed
end

local function SyncCastData(sourceCast: any, targetCast: any): boolean
	local sourceState = sourceCast.StateInfo
	local targetState = targetCast.StateInfo
	local targetTrajectory = targetState.Trajectory
	local changed = SyncFields(sourceState, targetState, PreservedStateFields)

	-- Keep the trajectory table stable because the simulator caches its reference.
	changed = SyncFields(sourceState.Trajectory, targetTrajectory) or changed
	targetState.Trajectory = targetTrajectory

	-- Resolve shape fields separately so RayInfo copying cannot hide CastVariant edits.
	changed = SyncFields(sourceCast.RayInfo, targetCast.RayInfo, PreservedShapeFields) or changed
	changed = SyncFields(sourceCast, targetCast, PreservedCastFields) or changed

	if sourceCast.UserData ~= targetCast.UserData then
		targetCast.UserData = sourceCast.UserData
		changed = true
	end

	return SyncCastVariant(sourceCast, targetCast) or changed
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
				local castChanged = SyncCastData(cast, TargetCast)
				ParallelSimulation.SyncCast(TargetCast, previousCosmetic)

				if castChanged then
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
