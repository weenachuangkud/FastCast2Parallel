--[[
	- Author : Mawin CK
	- Date : 2025
]]

local FastCastModule = script.Parent
local TypeDef = require(FastCastModule:WaitForChild("TypeDefinitions"))
local FastCastEnums = require(FastCastModule:WaitForChild("FastCastEnums"))

local DEFAULT_MAX_DISTANCE = 1000

local EnumCastTypes = FastCastEnums.CastType

type CastVariant = { CastType: number, Size: Vector3?, Radius: number? }

type BlockcastVariant = { CastType: number, Size: Vector3}
type SpherecastVariant = { CastType: number, Radius: number }
type RaycastVariant = { CastType: number }
type CastVariants = RaycastVariant | BlockcastVariant | SpherecastVariant


--[[local CastVariantTypes = {
	[EnumCastTypes.Raycast] = "Raycast",
	[EnumCastTypes.Blockcast] = "Blockcast",
	[EnumCastTypes.Spherecast] = "Spherecast"
}]]

local ActiveCast = {}

local function CloneCastParams(params: RaycastParams): RaycastParams
	local clone: RaycastParams = RaycastParams.new()
	clone.CollisionGroup = params.CollisionGroup
	clone.FilterType = params.FilterType
	clone.FilterDescendantsInstances = {table.unpack(params.FilterDescendantsInstances)}
	clone.IgnoreWater = params.IgnoreWater
	clone.RespectCanCollide = params.RespectCanCollide
	return clone
end

function ActiveCast.createCastData(
	BaseCast: any,
	activeCastID: number,
	origin: Vector3,
	direction: Vector3,
	velocity: Vector3 | number,
	behavior: TypeDef.FastCastBehavior,
	eventModule: TypeDef.FastCastEventsModule?,
	variant: CastVariants,
	_parallel: boolean?
): any
	local cast = {
		Caster = BaseCast,
		StateInfo = {
			TotalRuntime = 0,
			MaxLifetime = behavior.MaxLifetime,
			IsPaused = false,
			DistanceCovered = 0,
			MaxPiercesPerStep = behavior.MaxPiercesPerStep or 1,
			HighFidelitySegmentSize = behavior.HighFidelitySegmentSize,
			HighFidelityBehavior = behavior.HighFidelityBehavior,
			IsActivelyResimulating = false,
			CancelHighResCast = false,
			Trajectory = {
				StartTime = 0,
				EndTime = -1,
				Origin = origin,
				InitialVelocity = if typeof(velocity) == "number" then direction * velocity else velocity,
				Acceleration = behavior.Acceleration,
			},

			VisualizeCasts = behavior.VisualizeCasts,
			VisualizeCastSettings = behavior.VisualizeCastSettings,
		},

		RayInfo = {
			Parameters = behavior.RaycastParams and CloneCastParams(behavior.RaycastParams) or RaycastParams.new(),
			WorldRoot = workspace,
			MaxDistance = behavior.MaxDistance or DEFAULT_MAX_DISTANCE,
			CosmeticBulletObject = behavior.CosmeticBulletTemplate,
			FastCastEventsModule = eventModule
		},

		_Destroying = false,
		_TerminationQueued = false,
		Type = variant.CastType,
		CastVariant = variant,
		CFrame = CFrame.new(origin),
		ID = activeCastID,
		Mode = "Parallel",
		Offset = behavior.InitialOffset or CFrame.identity,
	}

	if variant.CastType == EnumCastTypes.Blockcast then
		cast.RayInfo.Size = (variant :: BlockcastVariant).Size
	elseif variant.CastType == EnumCastTypes.Spherecast then
		cast.RayInfo.Radius = (variant :: SpherecastVariant).Radius
	end

	if behavior.UserData then
		cast.UserData = behavior.UserData
	end

	local targetContainer: Instance?
	
	if cast.RayInfo.CosmeticBulletObject ~= nil then
		local basePart = cast.RayInfo.CosmeticBulletObject
		if behavior.CloneTemplate == true then
			basePart = basePart:Clone()
		end
		local initialCFrame = if direction ~= Vector3.new() then CFrame.new(origin, origin + direction) else CFrame.new(origin)
		basePart.CFrame = initialCFrame * cast.Offset
		cast.CFrame = initialCFrame * cast.Offset
		basePart.Parent = behavior.CosmeticBulletContainer

		cast.RayInfo.CosmeticBulletObject = basePart
	end

	if behavior.CosmeticBulletContainer then
		targetContainer = behavior.CosmeticBulletContainer
	end

	if behavior.AutoIgnoreContainer == true then
		local ignoreList = cast.RayInfo.Parameters.FilterDescendantsInstances
		local changed = false

		if targetContainer ~= nil and not table.find(ignoreList, targetContainer) then
			table.insert(ignoreList, targetContainer)
			changed = true
		end

		local cosmetic = cast.RayInfo.CosmeticBulletObject
		if cosmetic ~= nil and not table.find(ignoreList, cosmetic) then
			table.insert(ignoreList, cosmetic)
			changed = true
		end

		if changed then
			cast.RayInfo.Parameters.FilterDescendantsInstances = ignoreList
		end
	end

	return cast
end

return ActiveCast
