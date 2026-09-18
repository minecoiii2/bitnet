--!native
--!optimize 2

const ReplicatedStorage = game:GetService("ReplicatedStorage")
const Players = game:GetService("Players")

const USE_CUSTOM = false

local BucketSystem
const function customGetNearbyPlayers(at: Vector3, range: number)
	-- custom implementation here
	if not BucketSystem then
		BucketSystem = require(ReplicatedStorage.Systems.BucketSystem)
	end
	const arr = {}
	for i, v in BucketSystem.GetPlayersInRadius(at, range, true) do
		const player = Players:GetPlayerFromCharacter(v)
		if player then
			arr[#arr + 1] = player
		end
	end
	return arr
end

const playerList: { Player } = {}
const cachedCharacter: { [Player]: Model } = {}
const cachedRoot: { [Player]: BasePart } = {}

if not USE_CUSTOM then
	const function playerAdded(player: Player)
		if table.find(playerList, player) == nil then
			table.insert(playerList, player)
		end
	end

	for _, player in Players:GetPlayers() do
		playerAdded(player)
	end
	Players.PlayerAdded:Connect(playerAdded)
	Players.PlayerRemoving:Connect(function(player: Player)
		const index = table.find(playerList, player)
		if index then
			const last = #playerList
			playerList[index] = playerList[last]
			playerList[last] = nil
		end
		cachedCharacter[player] = nil
		cachedRoot[player] = nil
	end)
end

const function getNearbyPlayers(at: Vector3, range: number)
	const arr = {}
	if not (range >= 0) then
		return arr
	end
	const rangeSquared = range * range
	local count = 0
	for _, player in playerList do
		const character = player.Character
		if not character then continue end
		local root = cachedRoot[player]
		if cachedCharacter[player] ~= character or root == nil or root.Parent ~= character then
			root = character:FindFirstChild("HumanoidRootPart")
			cachedCharacter[player] = character
			cachedRoot[player] = root
		end
		if root then
			const offset = root.Position - at
			if offset.X * offset.X + offset.Y * offset.Y + offset.Z * offset.Z <= rangeSquared then
				count += 1
				arr[count] = player
			end
		end
	end
	return arr
end

return (if USE_CUSTOM then customGetNearbyPlayers else getNearbyPlayers) 
	:: (at: Vector3, range: number) -> {Player}