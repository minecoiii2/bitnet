--!native
--!optimize 2

-- u8 ids for types.player. The server hands each player one and publishes it as an attribute, which
-- replicates, so both sides map Player <-> id without the Instance ever riding the refs channel.

const Players = game:GetService("Players")
const RunService = game:GetService("RunService")
const IS_SERVER = RunService:IsServer()

const constants = require(script.Parent.Parent.constants)

const ATTRIBUTE = constants.PLAYER_ID_ATTRIBUTE
const MAX_ID = 255

const byId: { [number]: Player } = {}
const idOf: { [Player]: number } = {}

const function release(player: Player)
	const id = idOf[player]
	if id then
		idOf[player] = nil
		if byId[id] == player then
			byId[id] = nil
		end
	end
end

local idFor: (player: Player) -> number

if IS_SERVER then
	local lastId = 0

	-- round robin rather than lowest free, so a leaver's id is the last to be reused and a frame still
	-- in flight about them is least likely to resolve to whoever replaced them
	const function assign(player: Player): number
		for _ = 1, MAX_ID do
			lastId = lastId % MAX_ID + 1
			if byId[lastId] == nil then
				byId[lastId] = player
				idOf[player] = lastId
				player:SetAttribute(ATTRIBUTE, lastId)
				return lastId
			end
		end
		error(`bitnet: types.player ids are a u8, so at most {MAX_ID} players can hold one`)
	end

	idFor = function(player: Player): number
		const id = idOf[player]
		if id then
			return id
		end
		-- someone who already left gets no id; a receiver could only resolve it to nil anyway
		if player.Parent ~= Players then
			return 0
		end
		return assign(player)
	end

	Players.PlayerAdded:Connect(idFor)
	for _, player in Players:GetPlayers() do
		idFor(player)
	end
else
	const function track(player: Player)
		const function refresh()
			release(player)
			const id = player:GetAttribute(ATTRIBUTE)
			if type(id) == "number" then
				byId[id] = player
				idOf[player] = id
			end
		end
		refresh()
		player:GetAttributeChangedSignal(ATTRIBUTE):Connect(refresh)
	end

	idFor = function(player: Player): number
		const id = idOf[player] or player:GetAttribute(ATTRIBUTE)
		if type(id) ~= "number" then
			error(`bitnet: {player.Name} has no player id yet`, 0)
		end
		return id
	end

	Players.PlayerAdded:Connect(track)
	for _, player in Players:GetPlayers() do
		track(player)
	end
end

Players.PlayerRemoving:Connect(release)

return {
	byId = byId,
	idFor = idFor,
}
