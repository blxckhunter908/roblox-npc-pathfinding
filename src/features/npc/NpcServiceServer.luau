local ServerScriptService = game:GetService("ServerScriptService")

local NpcServer = require(
	ServerScriptService.Features.NPC.Classes.NpcServer
)

local NpcConfig = require(
	ServerScriptService.Features.NPC.Modules.NpcConfig
)

local NpcUtils = require(
	ServerScriptService.Features.NPC.Modules.NpcUtils
)

local NpcServiceServer = {}

function NpcServiceServer.init(self: NpcServiceServer): ()
	if self.npc then
		return
	end

	local model = workspace:WaitForChild(NpcConfig.npcModelName)
	local waypointContainer = workspace:WaitForChild(
		NpcConfig.waypointContainerName
	)

	assert(
		model:IsA("Model"),
		model:GetFullName() .. " must be a Model"
	)

	local waypoints = NpcUtils.getWaypoints(waypointContainer)

	assert(
		#waypoints >= 2,
		waypointContainer:GetFullName()
			.. " requires at least two waypoint parts"
	)

	-- Hide patrol waypoints during gameplay while keeping them available for NPC navigation.
	if NpcConfig.hideWaypoints then
		for _, waypoint in waypoints do
			waypoint.Transparency = 1
			waypoint.CanCollide = false
			waypoint.CanQuery = false
			waypoint.CanTouch = false
		end
	end

	-- Create the NPC controller only after the model and patrol route have been validated.
	self.npc = NpcServer.new(model, waypoints, NpcConfig)
	self.npc:start()
end

type NpcServiceServer = typeof(NpcServiceServer) & {
	npc: NpcServer.NpcServer?,
}

return NpcServiceServer :: NpcServiceServer
