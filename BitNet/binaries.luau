--!native
--!optimize 2

const Players = game:GetService("Players")
const RunService = game:GetService("RunService")
const IS_SERVER = RunService:IsServer()

const Bin = require(script.Parent.bin)

local reliableRemote = nil
local unreliableRemote = nil

const function newBin(kind: string, target: Player?)
	const b = Bin.new(kind)
	const reliable = kind == "reliable"
	b._kind = kind
	b._target = target
	b._remote = if reliable then reliableRemote else unreliableRemote
	return b
end

const globalReliable = newBin("reliable", nil)
const globalUnreliable = newBin("unreliable", nil)

const playersReliable: {[Player]: any} = {}
const playersUnreliable: {[Player]: any} = {}

const dirtyList = {}
local dirtyCount = 0

const function markDirty(bin)
	const count = dirtyCount + 1
	dirtyCount = count
	dirtyList[count] = bin
end

const function getDirty()
	return dirtyList, dirtyCount
end

const function clearDirty()
	table.clear(dirtyList)
	dirtyCount = 0
end

const function setRemotes(reliable, unreliable)
	reliableRemote = reliable
	unreliableRemote = unreliable
	globalReliable._remote = reliable
	globalUnreliable._remote = unreliable
	for _, bin in playersReliable do
		bin._remote = reliable
	end
	for _, bin in playersUnreliable do
		bin._remote = unreliable
	end
end

const module = {
	globalReliable = globalReliable,
	globalUnreliable = globalUnreliable,
	playersReliable = playersReliable,
	playersUnreliable = playersUnreliable,
	markDirty = markDirty,
	getDirty = getDirty,
	clearDirty = clearDirty,
	setRemotes = setRemotes,
}

if IS_SERVER then
	const function playerAdded(player: Player)
		playersReliable[player] = newBin("reliable", player)
		playersUnreliable[player] = newBin("unreliable", player)
	end

	for _, player in Players:GetPlayers() do
		playerAdded(player)
	end
	Players.PlayerAdded:Connect(playerAdded)
	Players.PlayerRemoving:Connect(function(player)
		const r = playersReliable[player]
		const u = playersUnreliable[player]
		if r then r._removed = true end
		if u then u._removed = true end
		playersReliable[player] = nil
		playersUnreliable[player] = nil
	end)
end

return module