local Players = game:GetService("Players")

local NpcConfig = require(script.Parent.NpcConfig)

type NpcConfig = NpcConfig.NpcConfig

local NpcUtils = {}

-- Use math.huge so unnumbered waypoints are sorted after numbered ones.
local function getWaypointIndex(name: string): number
	return tonumber(string.match(name, "%d+")) or math.huge
end

function NpcUtils.getWaypoints(container: Instance): { BasePart }
	local waypoints = {}

	for _, child in container:GetChildren() do
		if child:IsA("BasePart") then
			table.insert(waypoints, child)
		end
	end

	-- Sort numbered waypoints so the NPC follows the intended patrol order.
	table.sort(waypoints, function(a: BasePart, b: BasePart): boolean
		local aIndex = getWaypointIndex(a.Name)
		local bIndex = getWaypointIndex(b.Name)

		if aIndex == bIndex then
			return a.Name < b.Name
		end

		return aIndex < bIndex
	end)

	return waypoints
end

-- Start patrol from the waypoint closest to the NPC instead of always starting at waypoint 1.
function NpcUtils.getClosestWaypointIndex(
	position: Vector3,
	waypoints: { BasePart }
): number
	local closestIndex = 1
	local closestDistance = math.huge

	for index, waypoint in waypoints do
		local distance = (waypoint.Position - position).Magnitude

		if distance < closestDistance then
			closestDistance = distance
			closestIndex = index
		end
	end

	return closestIndex
end

function NpcUtils.getCharacterRoot(player: Player): BasePart?
	local character = player.Character
	if not character then
		return nil
	end

	local humanoid = character:FindFirstChildOfClass("Humanoid")
	local root = character:FindFirstChild("HumanoidRootPart")

	if not humanoid or humanoid.Health <= 0 then
		return nil
	end

	if not root or not root:IsA("BasePart") then
		return nil
	end

	return root
end

-- Ignore height differences because detection and chase range use horizontal distance.
function NpcUtils.getFlatDistance(a: Vector3, b: Vector3): number
	local offset = a - b
	return Vector3.new(offset.X, 0, offset.Z).Magnitude
end

function NpcUtils.hasLineOfSight(
	npcModel: Model,
	npcRoot: BasePart,
	targetRoot: BasePart
): boolean
	local targetCharacter = targetRoot.Parent
	if not targetCharacter then
		return false
	end

	-- The radius is 360 degrees; only a wall or another obstacle can block detection.
	local sightPart = npcModel:FindFirstChild("Head")
	local origin = if sightPart and sightPart:IsA("BasePart")
		then sightPart.Position
		else npcRoot.Position

	local targetPosition = targetRoot.Position + Vector3.new(0, 1.5, 0)
	local direction = targetPosition - origin

	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.FilterDescendantsInstances = { npcModel }
	raycastParams.IgnoreWater = true

	-- Raycast toward the target to make sure no obstacle is blocking the NPC's view.
	local result = workspace:Raycast(origin, direction, raycastParams)

	return result == nil
		or result.Instance:IsDescendantOf(targetCharacter)
end

function NpcUtils.getNearestVisiblePlayer(
	npcModel: Model,
	npcRoot: BasePart,
	config: NpcConfig
): (Player?, BasePart?)
	local closestPlayer: Player? = nil
	local closestRoot: BasePart? = nil
	local closestDistance = config.detectionRadius

	-- Keep the closest valid player that is inside the radius and visible to the NPC.
	for _, player in Players:GetPlayers() do
		local targetRoot = NpcUtils.getCharacterRoot(player)
		if not targetRoot then
			continue
		end

		-- Horizontal distance matches the circle that is visible on the ground.
		local distance = NpcUtils.getFlatDistance(
			targetRoot.Position,
			npcRoot.Position
		)

		if distance > closestDistance then
			continue
		end

		if not NpcUtils.hasLineOfSight(npcModel, npcRoot, targetRoot) then
			continue
		end

		closestPlayer = player
		closestRoot = targetRoot
		closestDistance = distance
	end

	return closestPlayer, closestRoot
end

return NpcUtils
