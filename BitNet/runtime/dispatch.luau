--!native
--!optimize 2

-- bridge

const RunService = game:GetService("RunService")
const IS_SERVER = RunService:IsServer()

const Bin = require(script.Parent.Parent.bin)
const binaries = require(script.Parent.Parent.binaries)
const registry = require(script.Parent.registry)
const remotes = require(script.Parent.remotes)
const constants = require(script.Parent.Parent.constants)
const codec = require(script.Parent.Parent.codec)
const Signal = require(script.Parent.Parent.instances.signal)

const Bin_snapshot = Bin.snapshot
const Bin_snapshotBools = Bin.snapshotBools
const Bin_flushBools = Bin.flushBools
const Bin_flush = Bin.flush
const Bin_recover = Bin.recover
const Bin_settle = Bin.settle
const getDirty = binaries.getDirty
const clearDirty = binaries.clearDirty
const getByteMode = registry.getByteMode
const bit_band = bit32.band
const buf_readu8 = buffer.readu8
const buf_len = buffer.len
const buf_create = buffer.create
const buf_copy = buffer.copy
const table_create = table.create
const table_move = table.move
const registry_ALL = registry.ALL
const EMPTY_REFS = {}
const EMPTY_BUFFER = buf_create(0)
const VALIDATE = constants.VALIDATE_INCOMING_TYPES
const cleanError = codec.cleanError
const _typeof = typeof

const module = {
	OnRejected = Signal.new(),
}

const function reject(player: Player?, entry, id: number?, reason: string)
	const source = if player then player.Name else "server"
	const subject = if entry then `bitnet.{entry.kind} #{id}` else "bitnet batch"
	warn(`{subject} from {source} rejected: {reason}`)
	module.OnRejected:Fire(player, id, reason)
end

const function malformed(player: Player?, id: number?, reason: string)
	if VALIDATE then
		reject(player, nil, id, reason)
	else
		warn(`bitnet: {reason}`)
	end
end

const function processBatch(player: Player?, buf: buffer, context, resetBools: boolean, dry: boolean?, start: number?)
	local cursor = if start then start else 0
	const len = buf_len(buf)
	const byteMode = getByteMode()
	while cursor < len do
		const first = buf_readu8(buf, cursor)
		local id
		if byteMode or first < 128 then
			id = first
			cursor += 1
		else
			if len - cursor < 2 then
				malformed(player, nil, "truncated frame header")
				return
			end

			const second = buf_readu8(buf, cursor + 1)
			if second < 128 then
				if second == 0 then
					malformed(player, nil, "malformed frame id")
					return
				end
				id = bit_band(first, 127) + second * 128
				cursor += 2
			else
				if len - cursor < 3 then
					malformed(player, nil, "truncated frame header")
					return
				end

				const third = buf_readu8(buf, cursor + 2)
				if third == 0 or third > 3 then
					malformed(player, nil, "malformed frame id")
					return
				end
				id = bit_band(first, 127) + bit_band(second, 127) * 128 + third * 16384
				cursor += 3
			end
		end

		const entry = registry_ALL[id]
		if not entry then
			malformed(player, id, `unknown id {id}, dropping rest of buffer`)
			return
		end

		context.frameId = id
		if resetBools then
			context.value = 256
		end
		if dry then
			context.frameStart = cursor
			context.frameRefs = context.refCount
			context.frameAmount = context.amount
			context.frameValue = context.value
			context.frameInflated = context.inflated
			context.frameEmpty = context.emptyRoom
			cursor = entry._skip(buf, cursor, context)
		else
			cursor = entry._handle(buf, cursor, context, player)
		end
	end
end

const MAX_SKIPPED_FRAMES = 16

const function rewindFrame(replay)
	replay.refCount = replay.frameRefs
	replay.amount = replay.frameAmount
	replay.value = replay.frameValue
	replay.inflated = replay.frameInflated
	replay.emptyRoom = replay.frameEmpty
end

const function dispatchValidated(player: Player?, buf: buffer, refs, bools: buffer, resetBools: boolean)
	local context = {
		refs = refs,
		refCount = 0,
		bools = bools,
		amount = 0,
		value = 256,
		readCursor = 0,
		frameId = 0,
		entries = registry_ALL,
	}
	local start, startRefs, startAmount, startValue, startInflated, startEmpty = 0, 0, 0, 256, nil, nil
	local skipped = 0
	while true do
		const ok, err = pcall(processBatch, player, buf, context, resetBools, false, start)
		if ok then
			return
		end

		const id = context.frameId
		const entry = registry_ALL[id]
		const valueFault = context.valueFault == true
		local reason = cleanError(err)
		local replay = nil
		if entry then
			replay = {
				refs = refs,
				refCount = startRefs,
				bools = bools,
				amount = startAmount,
				value = startValue,
				inflated = startInflated,
				emptyRoom = startEmpty,
				readCursor = 0,
				frameId = 0,
				entries = registry_ALL,
			}
			if not pcall(processBatch, player, buf, replay, resetBools, true, start) and replay.frameId == id then
				rewindFrame(replay)
				const found, path, detail = pcall(entry._diagnose, buf, replay.frameStart, replay)
				if found and detail then
					reason = if path == "" then detail else `{path}: {detail}`
				end
			else
				replay = nil
			end
		end
		reject(player, entry, if entry then id else nil, reason)

		if replay == nil or not valueFault or skipped >= MAX_SKIPPED_FRAMES then
			return
		end
		rewindFrame(replay)
		replay.valueFault = nil
		replay.skipNonFinite = true
		const decoded, nextCursor = pcall(entry._skip, buf, replay.frameStart, replay)
		replay.skipNonFinite = nil
		if not decoded then
			return
		end
		skipped += 1
		start = nextCursor
		startRefs, startAmount, startValue = replay.refCount, replay.amount, replay.value
		startInflated, startEmpty = replay.inflated, replay.emptyRoom
		context = replay
	end
end

const function dispatchIncoming(player: Player?, buf: buffer, recvRefs, recvBools, resetBools: boolean)
	if VALIDATE then
		if _typeof(buf) ~= "buffer"
			or (recvRefs ~= nil and type(recvRefs) ~= "table")
			or (recvBools ~= nil and _typeof(recvBools) ~= "buffer")
		then
			reject(player, nil, nil, `malformed batch of ({_typeof(buf)}, {_typeof(recvRefs)}, {_typeof(recvBools)})`)
			return
		end
		dispatchValidated(player, buf,
			if recvRefs then recvRefs else EMPTY_REFS,
			if recvBools then recvBools else EMPTY_BUFFER,
			resetBools)
		return
	end
	const context = {
		refs = if recvRefs then recvRefs else EMPTY_REFS,
		refCount = 0,
		bools = if recvBools then recvBools else EMPTY_BUFFER,
		amount = 0,
		value = 256,
		readCursor = 0,
		frameId = 0,
	}
	const ok, err = pcall(processBatch, player, buf, context, resetBools)
	if not ok then
		warn(`bitnet: failed to decode frame #{context.frameId}, dropping rest of buffer: {tostring(err)}`)
	end
end

if IS_SERVER then
	remotes.reliable.OnServerEvent:Connect(function(player, buf, recvRefs, recvBools)
		dispatchIncoming(player, buf, recvRefs, recvBools, false)
	end)
	remotes.unreliable.OnServerEvent:Connect(function(player, buf, recvRefs, recvBools)
		dispatchIncoming(player, buf, recvRefs, recvBools, true)
	end)
else
	remotes.reliable.OnClientEvent:Connect(function(buf, recvRefs, recvBools)
		dispatchIncoming(nil, buf, recvRefs, recvBools, false)
	end)
	remotes.unreliable.OnClientEvent:Connect(function(buf, recvRefs, recvBools)
		dispatchIncoming(nil, buf, recvRefs, recvBools, true)
	end)
end

const function sliceBuffer(src: buffer, from: number, to: number): buffer
	const len = to - from
	const out = buf_create(len)
	buf_copy(out, 0, src, from, len)
	return out
end

const function fire(re, target: Player?, payload: buffer, refs, bools: buffer?)
	if target then
		re:FireClient(target, payload, refs, bools)
	elseif IS_SERVER then
		re:FireAllClients(payload, refs, bools)
	else
		re:FireServer(payload, refs, bools)
	end
end

const reReliable = remotes.reliable
const reUnreliable = remotes.unreliable
binaries.setRemotes(reReliable, reUnreliable)

const function sendBin(bin)
	if bin.cursor == bin.safeCursor then
		Bin_recover(bin)
	end
	Bin_flushBools(bin)
	const target = bin._target
	const re = bin._remote
	const used = bin.cursor
	const splitCount = bin.splitCount
	const refCount = bin.refCount
	local refs = nil
	if refCount > 0 then
		refs = bin.refs
		bin.refs = {}
	end

	if splitCount == 0 then
		const snap = Bin_snapshot(bin)
		const snapBools = Bin_snapshotBools(bin)
		Bin_flush(bin)
		fire(re, target, snap, refs, snapBools)
		Bin_settle(bin, used)
		return
	end

	const buf = bin.buffer
	const splits = bin.splits
	const endAmount = bin.amount
	Bin_flush(bin)

	local fromCursor, fromAmount, fromRefs = 0, 0, 0
	local splitIndex = 1
	while true do
		local toCursor, toAmount, toRefs
		if splitIndex <= splitCount then
			toCursor = splits[splitIndex]
			toAmount = splits[splitIndex + 1]
			toRefs = splits[splitIndex + 2]
		else
			toCursor = used
			toAmount = endAmount
			toRefs = refCount
		end

		if toCursor > fromCursor then
			local chunkRefs = nil
			if toRefs > fromRefs then
				chunkRefs = table_create(toRefs - fromRefs)
				table_move(refs, fromRefs + 1, toRefs, 1, chunkRefs)
			end
			fire(
				re,
				target,
				sliceBuffer(buf, fromCursor, toCursor),
				chunkRefs,
				Bin_snapshotBools(bin, fromAmount, toAmount)
			)
		end

		if splitIndex > splitCount then
			break
		end
		fromCursor = toCursor
		fromAmount = toAmount
		fromRefs = toRefs
		splitIndex += 3
	end
	Bin_settle(bin, used)
end

if IS_SERVER then
	RunService.Heartbeat:Connect(function()
		const dirtyBins, dirtyCount = getDirty()
		for index = 1, dirtyCount do
			const bin = dirtyBins[index]
			if bin.cursor > 0 and not bin._removed then
				sendBin(bin)
			end
		end
		clearDirty()
	end)
else
	const globalReliable = binaries.globalReliable
	const globalUnreliable = binaries.globalUnreliable
	RunService.Heartbeat:Connect(function()
		if globalReliable.cursor > 0 then
			sendBin(globalReliable)
		end
		if globalUnreliable.cursor > 0 then
			sendBin(globalUnreliable)
		end
	end)
end

return module