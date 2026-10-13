# FastCast2Parallel Documentation

## 1. Caster

### 1.1 Parallel Caster (`FastCast.new()`)

Parallel Caster runs cast simulations on separate Actor VMs.

```lua
local caster = FastCast2.new()
caster:Init(
    numWorkers,          -- number of worker VMs (must be at least 1)
    movementMode,        -- "BulkMoveTo" or "Motor6D"
    fastCastEventsModule -- optional ModuleScript
)
```
> [!NOTE]
> FastCastParallel does not use Caster.CanPierce
> 
> Only available on FastCastEventsModule for performance reasons

#### 1.1.1 Parameters

| Parameter | Type | Description |
|-----------|------|-------------|
| `numWorkers` | `number` | Number of worker VMs. Must be at least 1. |
| `movementMode` | `"BulkMoveTo" | "Motor6D"` | Movement method |
| `fastCastEventsModule` | `ModuleScript?` | Optional FastCastEvents module |

#### 1.1.2 How It Works

- Creates Actor-based worker VMs using VMsDispatcher
- Each worker handles multiple casts in parallel via `ConnectParallel`
- Fire requests are round-robined to workers for load balancing

#### 1.1.3 Configuration Methods

```lua
caster:SetFastCastEventsModule(moduleScript)  -- Parallel only
caster:SetMovementModeEnabled(enabled, mode)

```

---

### 1.2 Fire Methods

The parallel caster supports all three fire methods:

```lua
caster:RaycastFire(origin, direction, velocity, BehaviorData?)
caster:BlockcastFire(origin, Size, direction, velocity, BehaviorData?)
caster:SpherecastFire(origin, Radius, direction, velocity, BehaviorData?)
```

- `velocity` can be a `Vector3` (exact velocity) or `number` (speed in the fire direction)
- `BehaviorData` is a `FastCastBehavior` created with `FastCast2.newBehavior()`

```lua
-- Raycast: simple line-of-sight
caster:RaycastFire(Vector3.new(0, 5, 0), Vector3.new(0, 0, -1), 500, behavior)

-- Blockcast: pass a Vector3 size after origin
caster:BlockcastFire(Vector3.new(0, 5, 0), Vector3.new(2, 4, 2), Vector3.new(0, 0, -1), 500, behavior)

-- Spherecast: pass a radius after origin
caster:SpherecastFire(Vector3.new(0, 5, 0), 3, Vector3.new(0, 0, -1), 500, behavior)
```

---

### 1.3 Cast Manipulation (static methods on `FastCast`)

```lua
-- Getters
FastCast:GetPositionCast(cast) → Vector3
FastCast:GetVelocityCast(cast) → Vector3
FastCast:GetAccelerationCast(cast) → Vector3

-- Setters (modifies trajectory, triggers CancelHighResCast)
FastCast:SetVelocityCast(cast, velocity) → ()
FastCast:SetAccelerationCast(cast, acceleration) → ()
FastCast:SetPositionCast(cast, position) → ()

-- Adders (relative modification)
FastCast:AddPositionCast(cast, position) → ()
FastCast:AddVelocityCast(cast, velocity) → ()
FastCast:AddAccelerationCast(cast, acceleration) → ()

-- Termination
FastCast:TerminateCast(cast) → ()
```

After modifying a cast, call `caster:SyncChangesToCast(cast)` after any Set/Add to push state to the worker VM.

```lua
-- Example: modify a cast mid-flight
local function onHit(cast, result, velocity, bullet)
	-- Deflect the projectile upward on hit
	FastCast.SetVelocityCast(cast, Vector3.new(0, 100, 0))
	FastCast.SetPositionCast(cast, result.Position + Vector3.new(0, 2, 0))

	-- In parallel mode, push changes to the worker VM
	if caster.SyncChangesToCast then
		caster:SyncChangesToCast(cast)
	end
end
```

---

### 1.4 Lifecycle

```lua
caster:Destroy()  -- Cleans up all resources, actors, caches
```

---

## 2. FastCastBehavior

Created via `FastCast2.newBehavior()`. Configuration for cast behavior:

```lua
local behavior = FastCast2.newBehavior()
behavior.MaxDistance = 500
behavior.RaycastParams = RaycastParams.new()
behavior.RaycastParams.FilterType = Enum.RaycastFilterType.Exclude
behavior.RaycastParams.FilterDescendantsInstances = {character}
behavior.Acceleration = Vector3.new(0, -workspace.Gravity, 0)
behavior.CosmeticBulletContainer = workspace.Projectiles
behavior.CosmeticBulletTemplate = ReplicatedStorage.Projectile
behavior.HighFidelityBehavior = FastCastEnums.HighFidelityBehavior.Automatic
behavior.HighFidelitySegmentSize = 0.5
behavior.VisualizeCasts = true
behavior.VisualizeCastSettings = {
	Debug_SegmentColor = Color3.new(1, 1, 0),
	Debug_HitColor = Color3.new(1, 0, 0),
}
```

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `RaycastParams` | `RaycastParams?` | `nil` | Filter rules for raycasting |
| `MaxDistance` | `number` | `1000` | Max range before auto-termination |
| `Acceleration` | `Vector3` | `(0,0,0)` | Constant acceleration applied each frame |
| `HighFidelityBehavior` | `number` | `1` | Default(1) / Automatic(2) / Always(3) |
| `HighFidelitySegmentSize` | `number` | `0.5` | Segment size for sub-stepping |
| `CosmeticBulletTemplate` | `BasePart?` | `nil` | Visual projectile part |
| `CosmeticBulletContainer` | `Instance?` | `nil` | Parent for non-cached bullets |
| `AutoIgnoreContainer` | `boolean` | `true` | Auto-adds container to filter list |
| `VisualizeCasts` | `boolean` | `false` | Debug visualization toggle |
| `VisualizeCastSettings` | `table` | (defaults) | Debug viz colors, sizes, lifetimes |
| `CloneTemplate` | `boolean` | `true` | Clone CosmeticBulletTemplate or not  |
| `UserData` | `any` | `nil` | Arbitrary data accessible on the cast |

### Event Configuration

```lua
behavior.FastCastEventsConfig = {
    UseLengthChanged = false,
    UseHit = true,
    UsePierced = true,
    UseCastTerminating = true,
    UseCanPierce = true,
    UseCastFire = true
}

behavior.FastCastEventsModuleConfig = {  -- Parallel only
    UseLengthChanged = false,
    UseHit = true,
    UsePierced = true,
    UseCastTerminating = true,
    UseCanPierce = true,
    UseCastFire = true
}
```

---

## 3. ActiveCastData

### 3.1 What is ActiveCast

ActiveCast represents a projectile in flight. It's a pure data structure (AoS) exposed to users, while internally FastCast2 uses SoA for performance.

### 3.2 Data Structure

```lua
cast.ID: number              -- Unique identifier
cast.CFrame: CFrame          -- Current cosmetic bullet CFrame
cast.UserData: any           -- From behavior.UserData
cast.CastVariant: {          -- Cast type info
    CastType: number,        -- 1=Raycast, 2=Blockcast, 3=Spherecast
    Size: Vector3?,          -- Blockcast only
    Radius: number?          -- Spherecast only
}
```

### 3.3 StateInfo

```lua
cast.StateInfo.TotalRuntime: number
cast.StateInfo.HighFidelityBehavior: number
cast.StateInfo.HighFidelitySegmentSize: number
cast.StateInfo.IsActivelyResimulating: boolean
cast.StateInfo.CancelHighResCast: boolean
cast.StateInfo.VisualizeCasts: boolean
cast.StateInfo.VisualizeCastSettings: VisualizeCastSettings
cast.StateInfo.FastCastEventsConfig: FastCastEventsConfig
cast.StateInfo.FastCastEventsModuleConfig: FastCastEventsModuleConfig  -- Parallel only

cast.StateInfo.Trajectory = {
    StartTime: number,
    EndTime: number,            -- -1 if still active
    Origin: Vector3,
    InitialVelocity: Vector3,
    Acceleration: Vector3
}
```

### 3.4 RayInfo

```lua
cast.RayInfo.Parameters: RaycastParams
cast.RayInfo.WorldRoot: WorldRoot
cast.RayInfo.MaxDistance: number
cast.RayInfo.CosmeticBulletObject: Instance?
cast.RayInfo.Size: Vector3       -- Blockcast only
cast.RayInfo.Radius: number      -- Spherecast only
```

---

## 4. FastCastEventsModule

Parallel-only. A `ModuleScript` that returns a `FastCastEvents` table for direct (non-BindableEvent) callbacks, providing better performance for high-frequency events like `LengthChanged`.

```lua
-- In a ModuleScript (e.g., ReplicatedStorage.FastCastEventsModule)
local module = {}

module.Hit = function(cast, result, velocity, bullet)
    print("Hit:", result.Instance)
end

module.CanPierce = function(cast, result, velocity, bullet)
    return result.Instance:GetAttribute("CanPierce") == true
end

module.LengthChanged = function(cast, lastPoint, rayDir, displacement)
    -- Called every frame - more efficient than BindableEvent routing
end

return module
```

Register it:
```lua
caster:SetFastCastEventsModule(pathToModule)
```

> **Note**: This event module is used by parallel workers for direct callbacks.

---

## 5. High-Fidelity Behavior

| Mode | Value | Description |
|------|-------|-------------|
| **Default** | `1` | Single cast per frame. Fastest, lowest accuracy. |
| **Automatic** | `2` | On hit, subdivides the frame's cast into sub-segments to find precise hit point. |
| **Always** | `3` | Always subdivides every frame. Most accurate, most expensive. |

`HighFidelitySegmentSize` controls the segment size for sub-stepping (default 0.5 studs).
