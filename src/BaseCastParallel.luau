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

-- Only fields listed here are copied from the source cast to the worker cast.
-- Runtime, distance, resimulation state, and CFrame remain worker-owned.
local MutableCastFields = {
	UserData = true,
	Type = true,

	StateInfo = {
		IsPaused = true,
		MaxLifetime = true,
		HighFidelitySegmentSize = true,
		HighFidelityBehavior = true,
		VisualizeCasts = true,

		Trajectory = {
			StartTime = true,
			EndTime = true,
			Origin = true,
			InitialVelocity = true,
			Acceleration = true,
		},

		FastCastEventsConfig = {
			UseLengthChanged = true,
			UseHit = true,
			UsePierced = true,
			UseCastTerminating = true,
			UseCanPierce = true,
			UseCastFire = true,
		},

		FastCastEventsModuleConfig = {
			UseLengthChanged = true,
			UseHit = true,
			UsePierced = true,
			UseCastTerminating = true,
			UseCanPierce = true,
			UseCastFire = true,
			UseOnStep = true,
		},

		VisualizeCastSettings = {
			Debug_SegmentColor = true,
			Debug_SegmentTransparency = true,
			Debug_SegmentSize = true,
			Debug_HitColor = true,
			Debug_HitTransparency = true,
			Debug_HitSize = true,
			Debug_RayPierceColor = true,
			Debug_RayPierceTransparency = true,
			Debug_RayPierceSize = true,
			Debug_RayLifetime = true,
			Debug_HitLifetime = true,
		},
	},

	RayInfo = {
		Parameters = true,
		WorldRoot = true,
		MaxDistance = true,
		CosmeticBulletObject = true,
		FastCastEventsModule = true,
		Size = true,
		Radius = true,
	},

	CastVariant = {
		CastType = true,
		Size = true,
		Radius = true,
	},
}

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

				for i, v in cast do
					local mutable = MutableCastFields[i]
					if mutable == true then
						TargetCast[i] = v
					elseif type(mutable) == "table" and type(v) == "table" and type(TargetCast[i]) == "table" then
						for k, nestedMutable in mutable do
							local sourceValue = v[k]
							if nestedMutable == true then
								TargetCast[i][k] = sourceValue
							elseif type(nestedMutable) == "table"
								and type(sourceValue) == "table"
								and type(TargetCast[i][k]) == "table"
							then
								for tk, fieldMutable in nestedMutable do
									if fieldMutable == true then
										TargetCast[i][k][tk] = sourceValue[tk]
									end
								end
							end
						end
					end
				end

				-- UserData may be nil, in which case it isn't present in the source
				-- table iteration above.
				TargetCast.UserData = cast.UserData
				ParallelSimulation.SyncCast(TargetCast, previousCosmetic)
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
