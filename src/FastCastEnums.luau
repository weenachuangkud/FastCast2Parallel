--[[
	- Author : Mawin CK
	- Date : 2025
	
]]

--!strict

--[=[

@class FastCastEnums
Enums for FastCast2.

]=]

local Enums = {}


--[=[

How High-Fidelity the cast simulation should be.
@type HighFidelityBehavior {Default, Automatic, Always}
@within FastCastEnums

]=]
Enums.HighFidelityBehavior = {
	Default = 1,
	Automatic = 2,
	Always = 3
}

Enums.CastType = {
	Raycast = 1,
	Blockcast = 2,
	Spherecast = 3
}

-- Numeric event IDs are shared by the main thread and parallel workers.
Enums.EventType = {
	LengthChanged = 1,
	Hit = 2,
	Pierced = 3,
	CastTerminating = 4,
	OnStep = 5,
	CastFire = 6,
	Batch = 7,
	CasterDestroyed = 8
}

return Enums
