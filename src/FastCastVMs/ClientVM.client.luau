--[[
	- Author : Mawin CK
	- Date : 11/03/2025
]]

-- Modules

-- Variables
local actor = script:GetActor()
if actor == nil then
	error("The script must placed inside of actor")
end

local BaseCastParallel = nil
local BaseCast = nil

-- Listeners

actor:BindToMessage("Init", function(Data: any?)
	BaseCastParallel = require(Data.FastCastModule:WaitForChild("BaseCastParallel"))
	BaseCast = BaseCastParallel.Init(
		script.Parent:WaitForChild("Output"), 
		Data
	)
end)

actor:BindToMessage("Raycast", function(
	casterId: number,
	origin: Vector3,
	direction: Vector3,
	velocity: Vector3 | number,
	behavior: any,
	eventModule: ModuleScript?
)
	BaseCast:Raycast(casterId, origin, direction, velocity, behavior, eventModule)
end)

--[[actor:BindToMessage("Blockcast", function(
	casterID : string,
	caster : TypeDefinitions.ActiveBlockCast,
	ID : string,
	origin : Vector3,
	size : Vector3,
	direction : Vector3 | number,
	velocity : Vector3,
	behavior : TypeDefinitions.FastCastBehavior?
)
	StoredCasts[casterID][ID] = ActiveBlockcast.new(caster, origin, size, direction, velocity, behavior)
end)]]

actor:BindToMessage("Blockcast", function(
	casterId: number,
	origin: Vector3,
	size: Vector3,
	direction: Vector3,
	velocity: Vector3 | number,
	behavior: any,
	eventModule: ModuleScript?
)
	BaseCast:Blockcast(casterId, origin, size, direction, velocity, behavior, eventModule)
end)

actor:BindToMessage("Spherecast", function(
	casterId: number,
	origin: Vector3,
	radius: number,
	direction: Vector3,
	velocity: Vector3 | number,
	behavior: any,
	eventModule: ModuleScript?
)
	BaseCast:Spherecast(casterId, origin, radius, direction, velocity, behavior, eventModule)
end)

actor:BindToMessage("FireBatch", function(requests: { any })
	for _, request in requests do
		local kind = request[1]
		if kind == 1 then
			BaseCast:Raycast(request[2], request[3], request[4], request[5], request[6], request[7])
		elseif kind == 2 then
			BaseCast:Blockcast(request[2], request[3], request[4], request[5], request[6], request[7], request[8])
		elseif kind == 3 then
			BaseCast:Spherecast(request[2], request[3], request[4], request[5], request[6], request[7], request[8])
		end
	end
end)

actor:BindToMessage("SetMovementModeEnabled", function(enabled: boolean, mode: "BulkMoveTo" | "Motor6D")
	BaseCast:SetMovementModeEnabled(enabled, mode)
end)

actor:BindToMessage("StopSimulation", function()
	BaseCast:StopSimulation()
end)

actor:BindToMessage("StartSimulation", function()
	BaseCast:StartSimulation()
end)

actor:BindToMessage("DestroyCaster", function(casterId: number)
	BaseCast:DestroyCaster(casterId)
end)

-- CleanUp

actor:BindToMessage("Destroy", function()
	BaseCast:Destroy()
	script.Parent:Destroy()
end)
