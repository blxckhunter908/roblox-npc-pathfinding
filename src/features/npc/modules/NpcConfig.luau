export type NpcConfig = {
	npcModelName: string,
	waypointContainerName: string,

	detectionRadius: number,
	detectionInterval: number,

	radiusColor: Color3,
	radiusTransparency: number,
	radiusHeight: number,
	radiusRayLength: number,

	patrolSpeed: number,
	chaseSpeed: number,
	patrolPause: number,

	chaseRepathInterval: number,
	chaseRepathDistance: number,
	chaseStopDistance: number,

	pathRetryDelay: number,
	pathWaypointReachedDistance: number,

	agentRadius: number,
	agentHeight: number,
	agentCanJump: boolean,
	agentCanClimb: boolean,
	waypointSpacing: number,

	hideWaypoints: boolean,
	debug: boolean,
}

local config: NpcConfig = {
	npcModelName = "NPC",
	waypointContainerName = "Path",

	detectionRadius = 160,
	detectionInterval = 0.1,

	radiusColor = Color3.fromRGB(255, 65, 65),
	radiusTransparency = 0.82,
	radiusHeight = 0.08,
	radiusRayLength = 300,

	patrolSpeed = 20,
	chaseSpeed = 30,
	patrolPause = 0.75,

	chaseRepathInterval = 0.45,
	chaseRepathDistance = 5,
	chaseStopDistance = 14,

	pathRetryDelay = 0.35,
	pathWaypointReachedDistance = 8,

	agentRadius = 12,
	agentHeight = 55,
	agentCanJump = true,
	agentCanClimb = false,
	waypointSpacing = 8,

	hideWaypoints = true,
	debug = true,
}

return config
