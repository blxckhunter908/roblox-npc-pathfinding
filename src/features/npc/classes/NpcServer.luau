local PathfindingService = game:GetService("PathfindingService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local NpcConfig = require(script.Parent.Parent.Modules.NpcConfig)
local NpcUtils = require(script.Parent.Parent.Modules.NpcUtils)

type Config = NpcConfig.NpcConfig
export type NpcState = "IDLE" | "PATROL" | "CHASE"

local NpcServer = {}
NpcServer.__index = NpcServer

export type NpcServer = typeof(setmetatable(
	{} :: {
		model: Model,
		humanoid: Humanoid,
		root: BasePart,
		waypoints: { BasePart },
		config: Config,
		state: NpcState,
		target: Player?,
		targetPosition: Vector3?,
		patrolIndex: number,
		pauseUntil: number,
		lastDetectionAt: number,
		lastChasePathAt: number,
		pathWaypoints: { PathWaypoint }?,
		pathWaypointIndex: number,
		pathDestination: Vector3?,
		pathRequestId: number,
		moveRequestId: number,
		isComputingPath: boolean,
		nextPathRequestAt: number,
		detectionVisualizer: Part,
		updateConn: RBXScriptConnection?,
		moveConn: RBXScriptConnection?,
		blockedConn: RBXScriptConnection?,
		diedConn: RBXScriptConnection?,
		destroyed: boolean,
	},
	NpcServer
	))

-- Keep NPC physics server-owned so movement stays consistent for every player.
local function setServerNetworkOwnership(model: Model): ()
	for _, descendant in model:GetDescendants() do
		if descendant:IsA("BasePart") and not descendant.Anchored then
			pcall(descendant.SetNetworkOwner, descendant, nil)
		end
	end
end

-- Create a visual representation of the NPC's detection radius for debugging.
local function createDetectionVisualizer(model: Model, config: Config): Part
	local visualizer = Instance.new("Part")
	visualizer.Name = model.Name .. "DetectionRadius"
	visualizer.Shape = Enum.PartType.Cylinder
	visualizer.Size = Vector3.new(0.12, config.detectionRadius * 2, config.detectionRadius * 2)
	visualizer.Color = config.radiusColor
	visualizer.Material = Enum.Material.Neon
	visualizer.Transparency = config.radiusTransparency
	visualizer.Anchored = true
	visualizer.CanCollide = false
	visualizer.CanQuery = false
	visualizer.CanTouch = false
	visualizer.CastShadow = false
	visualizer.Locked = true
	visualizer.Parent = workspace
	return visualizer
end

function NpcServer.new(model: Model, waypoints: { BasePart }, config: Config): NpcServer
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")

	assert(humanoid, model:GetFullName() .. " requires a Humanoid")
	assert(root and root:IsA("BasePart"), model:GetFullName() .. " requires a HumanoidRootPart")
	assert(#waypoints >= 2, "NpcServer requires at least two patrol waypoints")

	local self = setmetatable({
		model = model,
		humanoid = humanoid,
		root = root,
		waypoints = waypoints,
		config = config,
		state = "IDLE" :: NpcState,
		target = nil,
		targetPosition = nil,
		patrolIndex = NpcUtils.getClosestWaypointIndex(root.Position, waypoints),
		pauseUntil = 0,
		lastDetectionAt = 0,
		lastChasePathAt = 0,
		pathWaypoints = nil,
		pathWaypointIndex = 0,
		pathDestination = nil,
		pathRequestId = 0,
		moveRequestId = 0,
		isComputingPath = false,
		nextPathRequestAt = 0,
		detectionVisualizer = createDetectionVisualizer(model, config),
		updateConn = nil,
		moveConn = nil,
		blockedConn = nil,
		diedConn = nil,
		destroyed = false,
	}, NpcServer) :: NpcServer

	model.PrimaryPart = root
	model:SetAttribute("State", self.state)
	model:SetAttribute("TargetUserId", nil)
	model:SetAttribute("DetectionRadius", config.detectionRadius)

	setServerNetworkOwnership(model)
	self:updateDetectionVisualizer()

	return self
end

function NpcServer.debugPrint(self: NpcServer, ...: any): ()
	if self.config.debug then
		print("[NpcServer]", ...)
	end
end

function NpcServer.setTarget(self: NpcServer, target: Player?, targetRoot: BasePart?): ()
	self.target = target
	self.targetPosition = if targetRoot then targetRoot.Position else nil
	self.model:SetAttribute("TargetUserId", if target then target.UserId else nil)
end

-- Invalidate previous navigation requests before stopping the current path.
function NpcServer.stopNavigation(self: NpcServer, halt: boolean): ()
	self.pathRequestId += 1
	self.moveRequestId += 1
	self.isComputingPath = false
	self.pathWaypoints = nil
	self.pathWaypointIndex = 0
	self.pathDestination = nil

	if self.moveConn then
		self.moveConn:Disconnect()
		self.moveConn = nil
	end

	if self.blockedConn then
		self.blockedConn:Disconnect()
		self.blockedConn = nil
	end

	if halt and self.root.Parent then
		self.humanoid:MoveTo(self.root.Position)
	end
end

-- Reset navigation when switching states so the previous state's path cannot continue.
function NpcServer.setState(self: NpcServer, nextState: NpcState): ()
	if self.state == nextState then
		return
	end

	self:debugPrint(self.state, "->", nextState)

	self:stopNavigation(true)
	self.state = nextState
	self.model:SetAttribute("State", nextState)

	if nextState == "PATROL" then
		self:setTarget(nil, nil)
		self.patrolIndex = NpcUtils.getClosestWaypointIndex(self.root.Position, self.waypoints)
		self.pauseUntil = 0
	elseif nextState == "CHASE" then
		self.lastChasePathAt = 0
	elseif nextState == "IDLE" then
		self:setTarget(nil, nil)
	end
end

function NpcServer.followCurrentPathWaypoint(self: NpcServer): ()
	local pathWaypoints = self.pathWaypoints
	if not pathWaypoints then
		return
	end

	local waypoint = pathWaypoints[self.pathWaypointIndex]
	if not waypoint then
		self:onDestinationReached()
		return
	end

	if waypoint.Action == Enum.PathWaypointAction.Jump then
		self.humanoid.Jump = true
	end

	-- Track each MoveTo request so callbacks from old movements can be ignored.
	self.moveRequestId += 1
	local moveRequestId = self.moveRequestId

	if self.moveConn then
		self.moveConn:Disconnect()
	end

	self.moveConn = self.humanoid.MoveToFinished:Connect(function(reached: boolean)
		if self.destroyed or moveRequestId ~= self.moveRequestId then
			return
		end

		if self.moveConn then
			self.moveConn:Disconnect()
			self.moveConn = nil
		end

		if reached then
			self.pathWaypointIndex += 1
			self:followCurrentPathWaypoint()
		else
			self:recalculatePath()
		end
	end)

	self.humanoid:MoveTo(waypoint.Position)
end

function NpcServer.onDestinationReached(self: NpcServer): ()
	if self.blockedConn then
		self.blockedConn:Disconnect()
		self.blockedConn = nil
	end

	self.pathWaypoints = nil
	self.pathWaypointIndex = 0
	self.pathDestination = nil

	if self.state == "PATROL" then
		self.patrolIndex = (self.patrolIndex % #self.waypoints) + 1
		self.pauseUntil = os.clock() + self.config.patrolPause
	end
end

function NpcServer.navigateTo(self: NpcServer, destination: Vector3, force: boolean?): ()
	if self.destroyed or self.isComputingPath then
		return
	end

	if not force and os.clock() < self.nextPathRequestAt then
		return
	end

	-- Give each path request an ID so outdated path results can be ignored.
	self.pathRequestId += 1
	local pathRequestId = self.pathRequestId

	self.moveRequestId += 1

	if self.moveConn then
		self.moveConn:Disconnect()
		self.moveConn = nil
	end

	if self.blockedConn then
		self.blockedConn:Disconnect()
		self.blockedConn = nil
	end

	self.pathWaypoints = nil
	self.pathWaypointIndex = 0
	self.pathDestination = destination
	self.isComputingPath = true
	self.nextPathRequestAt = os.clock() + self.config.pathRetryDelay

	local path = PathfindingService:CreatePath({
		AgentRadius = self.config.agentRadius,
		AgentHeight = self.config.agentHeight,
		AgentCanJump = self.config.agentCanJump,
		AgentCanClimb = self.config.agentCanClimb,
		WaypointSpacing = self.config.waypointSpacing,
	})

	-- Compute the path separately so pathfinding does not block the main update loop.
	task.spawn(function()
		local success, errorMessage = pcall(
			path.ComputeAsync,
			path,
			self.root.Position,
			destination
		)

		-- Ignore this result if a newer path was requested while this one was computing.
		if self.destroyed or pathRequestId ~= self.pathRequestId then
			return
		end

		self.isComputingPath = false

		if not success or path.Status ~= Enum.PathStatus.Success then
			if self.config.debug then
				warn("[NpcServer] Path failed:", errorMessage or path.Status.Name)
			end

			return
		end

		local pathWaypoints = path:GetWaypoints()
		if #pathWaypoints == 0 then
			return
		end

		self.pathWaypoints = pathWaypoints
		self.pathWaypointIndex = 1

		if
			#pathWaypoints > 1
			and (pathWaypoints[1].Position - self.root.Position).Magnitude
			<= self.config.pathWaypointReachedDistance
		then
			self.pathWaypointIndex = 2
		end

		self.blockedConn = path.Blocked:Connect(function(blockedIndex: number)
			-- Only recalculate when the blocked waypoint is still ahead of the NPC.
			if blockedIndex >= self.pathWaypointIndex then
				self:recalculatePath()
			end
		end)

		self:followCurrentPathWaypoint()
	end)
end

function NpcServer.recalculatePath(self: NpcServer): ()
	local destination = self.pathDestination
	if not destination then
		return
	end

	self:debugPrint("Path blocked - recalculating")

	self:stopNavigation(false)
	self.nextPathRequestAt = 0
	self:navigateTo(destination, true)
end

-- Raycast downward to keep the detection circle aligned with the ground.
function NpcServer.updateDetectionVisualizer(self: NpcServer): ()
	local raycastParams = RaycastParams.new()
	raycastParams.FilterType = Enum.RaycastFilterType.Exclude
	raycastParams.IgnoreWater = true

	local exclusions: { Instance } = {
		self.model,
		self.detectionVisualizer,
	}

	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(exclusions, player.Character)
		end
	end

	raycastParams.FilterDescendantsInstances = exclusions

	local origin = self.root.Position + Vector3.new(0, 10, 0)
	local result = workspace:Raycast(
		origin,
		Vector3.new(0, -self.config.radiusRayLength, 0),
		raycastParams
	)

	local groundY = if result
		then result.Position.Y
		else self.root.Position.Y - self.humanoid.HipHeight - self.root.Size.Y * 0.5

	self.detectionVisualizer.CFrame = CFrame.new(
		self.root.Position.X,
		groundY + self.config.radiusHeight,
		self.root.Position.Z
	) * CFrame.Angles(0, 0, math.rad(90))
end

function NpcServer.updateDetection(self: NpcServer, now: number): ()
	if now - self.lastDetectionAt < self.config.detectionInterval then
		return
	end

	self.lastDetectionAt = now

	local target, targetRoot = NpcUtils.getNearestVisiblePlayer(
		self.model,
		self.root,
		self.config
	)

	if target and targetRoot then
		self:setTarget(target, targetRoot)

		if self.state ~= "CHASE" then
			self:setState("CHASE")
		end

		return
	end

	-- Leaving the circle or hiding behind cover cancels chase immediately.
	if self.state == "CHASE" then
		self:setState("PATROL")
	end
end

function NpcServer.updatePatrol(self: NpcServer, now: number): ()
	self.humanoid.WalkSpeed = self.config.patrolSpeed

	if now < self.pauseUntil then
		return
	end

	if self.pathWaypoints or self.isComputingPath then
		return
	end

	self:navigateTo(self.waypoints[self.patrolIndex].Position)
end

function NpcServer.updateChase(self: NpcServer, now: number): ()
	self.humanoid.WalkSpeed = self.config.chaseSpeed

	local destination = self.targetPosition
	if not destination then
		self:setState("PATROL")
		return
	end

	if NpcUtils.getFlatDistance(self.root.Position, destination) <= self.config.chaseStopDistance then
		if self.pathWaypoints or self.isComputingPath then
			self:stopNavigation(true)
		end

		return
	end

	if now - self.lastChasePathAt < self.config.chaseRepathInterval then
		return
	end

	-- Keep the current path if the target has not moved far enough to require a new one.
	if
		self.pathDestination
		and (self.pathDestination - destination).Magnitude < self.config.chaseRepathDistance
		and (self.pathWaypoints or self.isComputingPath)
	then
		return
	end

	self.lastChasePathAt = now
	self:navigateTo(destination)
end

function NpcServer.update(self: NpcServer, _dt: number): ()
	if self.destroyed or self.humanoid.Health <= 0 then
		return
	end

	local now = os.clock()

	self:updateDetectionVisualizer()
	self:updateDetection(now)

	if self.state == "PATROL" then
		self:updatePatrol(now)
	elseif self.state == "CHASE" then
		self:updateChase(now)
	end
end

function NpcServer.start(self: NpcServer): ()
	if self.updateConn or self.destroyed then
		return
	end

	self:setState("PATROL")

	self.updateConn = RunService.Heartbeat:Connect(function(dt: number)
		self:update(dt)
	end)

	self.diedConn = self.humanoid.Died:Connect(function()
		self:destroy()
	end)
end

-- Clean up connections and the debug visualizer when the NPC is destroyed.
function NpcServer.destroy(self: NpcServer): ()
	if self.destroyed then
		return
	end

	self.destroyed = true
	self:stopNavigation(true)

	if self.updateConn then
		self.updateConn:Disconnect()
		self.updateConn = nil
	end

	if self.diedConn then
		self.diedConn:Disconnect()
		self.diedConn = nil
	end

	if self.detectionVisualizer then
		self.detectionVisualizer:Destroy()
	end
end

return NpcServer
