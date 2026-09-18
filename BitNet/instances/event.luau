--!native
--!optimize 2

const Players = game:GetService("Players")
const ReplicatedStorage = game:GetService("ReplicatedStorage")
const RunService = game:GetService("RunService")
const IS_SERVER = RunService:IsServer()

const Bin = require(script.Parent.Parent.bin)
const binaries = require(script.Parent.Parent.binaries)
const registry = require(script.Parent.Parent.runtime.registry)
const Signal = require(script.Parent.signal)
const constants = require(script.Parent.Parent.constants)
const codec = require(script.Parent.Parent.codec)
const assertAt = require(script.Parent.Parent.libs.assertAt)
const getNearbyPlayers = require(script.Parent.Parent.libs.getNearbyPlayers)

const Bin_reserve = Bin.reserve
const Bin_tryWrite = Bin.tryWrite
const Bin_flushBools = Bin.flushBools
const markDirty = binaries.markDirty
const getHeader = registry.getHeader
const rateLimitAllowed = registry.rateLimitAllowed
const buf_writeu8 = buffer.writeu8
const buf_writeu16 = buffer.writeu16
const buf_copy = buffer.copy
const bit_lshift = bit32.lshift
const bit_countlz = bit32.countlz
const table_unpack = table.unpack
const locate = codec.locate

const MAX_UNRELIABLE_BYTES = constants.MAX_UNRELIABLE_BYTES
const REF_BYTES = constants.UNRELIABLE_REF_BYTES

const module = {
	ALL = registry.ALL,
}

const scratch = Bin.new("unreliable")

const function resetScratch()
	const refs = scratch.refs
	for index = 1, scratch.refCount do
		refs[index] = nil
	end
	scratch.cursor = 0
	scratch.refCount = 0
	scratch.amount = 0
	scratch.value = 1
	scratch.splitCount = 0
	scratch.chunkCursor = 0
	scratch.chunkAmount = 0
end

const function appendScratch(bin, unreliable: boolean)
	const frameBytes = scratch.cursor
	const c0 = bin.cursor
	if c0 == 0 then
		markDirty(bin)
	end
	if c0 + frameBytes > bin.size then
		Bin_reserve(bin, frameBytes)
	end
	buf_copy(bin.buffer, c0, scratch.buffer, 0, frameBytes)
	const c1 = c0 + frameBytes
	bin.cursor = c1

	Bin_flushBools(bin)
	const a0 = bin.amount
	const boolBytes = scratch.amount
	if boolBytes > 0 then
		const src = scratch.bools
		const dst = bin.bools
		for index = 1, boolBytes do
			dst[a0 + index] = src[index]
		end
		bin.amount = a0 + boolBytes
	end

	const r0 = bin.refCount
	const refCount = scratch.refCount
	if refCount > 0 then
		const src = scratch.refs
		const dst = bin.refs
		for index = 1, refCount do
			dst[r0 + index] = src[index]
		end
		bin.refCount = r0 + refCount
	end

	if unreliable and c1 - bin.chunkCursor + a0 + boolBytes - bin.chunkAmount + (bin.refCount - bin.chunkRefs) * REF_BYTES > MAX_UNRELIABLE_BYTES then
		const splitCount = bin.splitCount
		const splits = bin.splits
		splits[splitCount + 1] = c0
		splits[splitCount + 2] = a0
		splits[splitCount + 3] = r0
		bin.splitCount = splitCount + 3
		bin.chunkCursor = c0
		bin.chunkAmount = a0
		bin.chunkRefs = r0
	end
end


-- Define a remote event
--   options.Args      -- payload
--   options.Reliable  -- defaults to true
--   options.RateLimit -- server-side gate
--   options.ValidateOutgoing -- check values against the schema before send (default: constants.VALIDATE_OUTGOING_TYPES)
function module.new(options: {
	Args: any,
	Reliable: boolean?,
	ValidateOutgoing: boolean?,
	RateLimit: { calls: number, per: number }?,
	ValidateAcceptNonFinite: boolean?,
	Debug: boolean?,
})
	assertAt(type(options) == 'table', "bitnet.event: options expected a table")
	
	const debugEnabled = options.Debug == true
	const schema = options.Args
	const reliable = options.Reliable ~= false
	assertAt(options.Typecheck == nil, "bitnet.event: options.Typecheck is now ValidateOutgoing", 2)
	const typecheck = if options.ValidateOutgoing == nil then constants.VALIDATE_OUTGOING_TYPES else options.ValidateOutgoing

	assertAt(schema, "bitnet.event: options.Args is required", 2)
	assertAt(schema.write and schema.read,
		"bitnet.event: options.Args is not a compiled bitnet type", 2)

	const isTuple = schema._isTuple == true
	const arity = schema._arity
	
	const sig = Signal.new(not IS_SERVER)

	const self = {
		kind = "event",
		id = 0,
		debugEnabled = debugEnabled,
		schema = schema,
		reliable = reliable,
		isTuple = isTuple,
		arity = arity,
		rateLimit = options.RateLimit,
		rateState = if options.RateLimit
			then setmetatable({}, { __mode = "k" })
			else nil,
		_acceptNonFinite = if options.ValidateAcceptNonFinite == nil
			then not constants.VALIDATE_DEFAULT_REJECT_NON_FINITE
			else options.ValidateAcceptNonFinite,
		OnServerEvent = sig,
		OnClientEvent = sig,
		OnReceived = sig,
	}

	registry.register(self)
	const id = self.id

	self._diagnose = function(buf, cursor, context)
		return locate(schema, buf, cursor, context, "")
	end

	const spread = isTuple and schema._writeArgs ~= nil
	const packed = isTuple and not spread
	const payloadSize = schema.size
	const payloadSizeOf = if spread then schema._sizeArgs else schema.sizeOf
	const payloadWrite = if spread then schema._writeArgs else schema.write
	const payloadRead = if spread then schema._readArgs else schema.read

	self._skip = if spread
		then function(buf, cursor, context)
			payloadRead(buf, cursor, context)
			return context.readCursor
		end
		else function(buf, cursor, context)
			const _, nextCursor = payloadRead(buf, cursor, context)
			return nextCursor
		end
	const rateLimited = self.rateLimit ~= nil
	const costly = schema._costly == true

	local hdrSize = 0
	local hdrLow = 0
	local hdrHigh = 0
	local sizeHint = 64

	local writeFrame
	if reliable and costly then
		writeFrame = function(bin, v1, v2, v3, v4, v5, v6)
			if hdrSize == 0 then
				hdrSize, hdrLow, hdrHigh = getHeader(self)
			end
			const c0 = bin.cursor
			const a0 = bin.amount
			const r0 = bin.refCount
			const need = hdrSize + sizeHint
			if c0 + need > bin.size then
				Bin_reserve(bin, need)
			end
			const b = bin.buffer
			if hdrSize == 1 then
				buf_writeu8(b, c0, hdrLow)
			else
				buf_writeu16(b, c0, hdrLow)
				if hdrSize == 3 then
					buf_writeu8(b, c0 + 2, hdrHigh)
				end
			end
			const payloadAt = c0 + hdrSize
			const c1 = Bin_tryWrite(bin, payloadAt, a0, r0, payloadWrite, v1, v2, v3, v4, v5, v6)
			bin.cursor = c1
			sizeHint = c1 - payloadAt
		end
	elseif reliable then
		writeFrame = function(bin, v1, v2, v3, v4, v5, v6)
			if hdrSize == 0 then
				hdrSize, hdrLow, hdrHigh = getHeader(self)
			end
			const c = bin.cursor
			const need = hdrSize + (payloadSize or payloadSizeOf(v1, v2, v3, v4, v5, v6))
			if c + need > bin.size then
				Bin_reserve(bin, need)
			end
			const b = bin.buffer
			if hdrSize == 1 then
				buf_writeu8(b, c, hdrLow)
			else
				buf_writeu16(b, c, hdrLow)
				if hdrSize == 3 then
					buf_writeu8(b, c + 2, hdrHigh)
				end
			end
			bin.cursor = payloadWrite(b, c + hdrSize, v1, bin, v2, v3, v4, v5, v6)
		end
	elseif costly then
		writeFrame = function(bin, v1, v2, v3, v4, v5, v6)
			if hdrSize == 0 then
				hdrSize, hdrLow, hdrHigh = getHeader(self)
			end
			const c0 = bin.cursor
			const a0 = bin.amount
			const r0 = bin.refCount
			const need = hdrSize + sizeHint
			if c0 + need > bin.size then
				Bin_reserve(bin, need)
			end
			const b = bin.buffer
			if hdrSize == 1 then
				buf_writeu8(b, c0, hdrLow)
			else
				buf_writeu16(b, c0, hdrLow)
				if hdrSize == 3 then
					buf_writeu8(b, c0 + 2, hdrHigh)
				end
			end
			const payloadAt = c0 + hdrSize
			const c1 = Bin_tryWrite(bin, payloadAt, a0, r0, payloadWrite, v1, v2, v3, v4, v5, v6)
			bin.cursor = c1
			sizeHint = c1 - payloadAt
			local a1 = bin.amount
			const boolValue = bin.value
			if boolValue ~= 1 then
				a1 += 1
				bin.bools[a1] = bit_lshift(boolValue, bit_countlz(boolValue) - 23) - 256
				bin.amount = a1
				bin.value = 1
			end

			const r1 = bin.refCount
			const frameBytes = c1 - c0 + a1 - a0 + (r1 - r0) * REF_BYTES
			if frameBytes > MAX_UNRELIABLE_BYTES then
				warn(`bitnet: single unreliable fire is {frameBytes} bytes, exceeds {MAX_UNRELIABLE_BYTES} cap; dropping fire`)
				bin.cursor = c0
				bin.amount = a0
				if r1 > r0 then
					const refs = bin.refs
					for index = r0 + 1, r1 do
						refs[index] = nil
					end
					bin.refCount = r0
				end
			elseif c1 - bin.chunkCursor + a1 - bin.chunkAmount + (r1 - bin.chunkRefs) * REF_BYTES > MAX_UNRELIABLE_BYTES then
				const splitCount = bin.splitCount
				const splits = bin.splits
				splits[splitCount + 1] = c0
				splits[splitCount + 2] = a0
				splits[splitCount + 3] = r0
				bin.splitCount = splitCount + 3
				bin.chunkCursor = c0
				bin.chunkAmount = a0
				bin.chunkRefs = r0
			end
		end
	else
		writeFrame = function(bin, v1, v2, v3, v4, v5, v6)
			if hdrSize == 0 then
				hdrSize, hdrLow, hdrHigh = getHeader(self)
			end
			const c0 = bin.cursor
			const a0 = bin.amount
			const r0 = bin.refCount
			const need = hdrSize + (payloadSize or payloadSizeOf(v1, v2, v3, v4, v5, v6))
			if c0 + need > bin.size then
				Bin_reserve(bin, need)
			end
			const b = bin.buffer
			if hdrSize == 1 then
				buf_writeu8(b, c0, hdrLow)
			else
				buf_writeu16(b, c0, hdrLow)
				if hdrSize == 3 then
					buf_writeu8(b, c0 + 2, hdrHigh)
				end
			end
			const c1 = payloadWrite(b, c0 + hdrSize, v1, bin, v2, v3, v4, v5, v6)
			bin.cursor = c1
			local a1 = bin.amount
			const boolValue = bin.value
			if boolValue ~= 1 then
				a1 += 1
				bin.bools[a1] = bit_lshift(boolValue, bit_countlz(boolValue) - 23) - 256
				bin.amount = a1
				bin.value = 1
			end

			const r1 = bin.refCount
			const frameBytes = c1 - c0 + a1 - a0 + (r1 - r0) * REF_BYTES
			if frameBytes > MAX_UNRELIABLE_BYTES then
				warn(`bitnet: single unreliable fire is {frameBytes} bytes, exceeds {MAX_UNRELIABLE_BYTES} cap; dropping fire`)
				bin.cursor = c0
				bin.amount = a0
				if r1 > r0 then
					const refs = bin.refs
					for index = r0 + 1, r1 do
						refs[index] = nil
					end
					bin.refCount = r0
				end
			elseif c1 - bin.chunkCursor + a1 - bin.chunkAmount + (r1 - bin.chunkRefs) * REF_BYTES > MAX_UNRELIABLE_BYTES then
				const splitCount = bin.splitCount
				const splits = bin.splits
				splits[splitCount + 1] = c0
				splits[splitCount + 2] = a0
				splits[splitCount + 3] = r0
				bin.splitCount = splitCount + 3
				bin.chunkCursor = c0
				bin.chunkAmount = a0
				bin.chunkRefs = r0
			end
		end
	end

	const function validate(...)
		if not isTuple and select('#', ...) > 1 then
			error(`bitnet.event #{id} outgoing validation failed: too many values`, 3)
		end
		const value = if isTuple then {...} else (...)
		const ok, err = schema.check(value)
		if not ok then
			error(`bitnet.event #{id} outgoing validation failed: {err}`, 3)
		end
	end

	if IS_SERVER then
		const globalBin = if reliable then binaries.globalReliable else binaries.globalUnreliable
		const playerBins = if reliable then binaries.playersReliable else binaries.playersUnreliable
		const unreliable = not reliable

		function self:FireServer()
			error(`bitnet.event #{id}:FireServer called on server`, 2)
		end

		if typecheck or packed then
			function self:FireClient(player: Player, ...)
				if typecheck then
					validate(...)
				end
				const bin = playerBins[player]
				if not bin then return end
				if bin.cursor == 0 then
					markDirty(bin)
				end
				if packed then
					writeFrame(bin, {...})
				else
					writeFrame(bin, ...)
				end
			end

			function self:FireAllClients(...)
				if typecheck then
					validate(...)
				end
				if globalBin.cursor == 0 then
					markDirty(globalBin)
				end
				if packed then
					writeFrame(globalBin, {...})
				else
					writeFrame(globalBin, ...)
				end
			end
		else
			function self:FireClient(player: Player, v1, v2, v3, v4, v5, v6)
				const bin = playerBins[player]
				if not bin then return end
				if bin.cursor == 0 then
					markDirty(bin)
				end
				writeFrame(bin, v1, v2, v3, v4, v5, v6)
			end

			function self:FireAllClients(v1, v2, v3, v4, v5, v6)
				if globalBin.cursor == 0 then
					markDirty(globalBin)
				end
				writeFrame(globalBin, v1, v2, v3, v4, v5, v6)
			end
		end

		const function streamFrame(players: { Player }, exclude: Player?, ...)
			resetScratch()
			if packed then
				writeFrame(scratch, {...})
			else
				writeFrame(scratch, ...)
			end
			Bin_flushBools(scratch)
			if scratch.cursor > 0 then
				for _, player in players do
					if player == exclude then continue end
					const bin = playerBins[player]
					if bin then
						appendScratch(bin, unreliable)
					end
				end
			end
			resetScratch()
		end

		function self:FireClientsStreamed(at: Vector3, streamingRange: number, ...)
			const players = getNearbyPlayers(at, streamingRange)
			if #players == 0 then return end
			if typecheck then
				validate(...)
			end
			streamFrame(players, nil, ...)
		end

		function self:FireClientsStreamedWithExclusion(at: Vector3, streamingRange: number, exclude: Player, ...)
			const players = getNearbyPlayers(at, streamingRange)
			if #players == 0 then return end
			if typecheck then
				validate(...)
			end
			streamFrame(players, exclude, ...)
		end
	else
		const globalBin = if reliable then binaries.globalReliable else binaries.globalUnreliable

		const function serverOnly(method: string)
			return function()
				error(`bitnet.event #{id}:{method} called on client`, 2)
			end
		end
		self.FireClient = serverOnly("FireClient")
		self.FireAllClients = serverOnly("FireAllClients")
		self.FireClientsStreamed = serverOnly("FireClientsStreamed")
		self.FireClientsStreamedWithExclusion = serverOnly("FireClientsStreamedWithExclusion")

		if typecheck or packed then
			function self:FireServer(...)
				if typecheck then
					validate(...)
				end
				if packed then
					writeFrame(globalBin, {...})
				else
					writeFrame(globalBin, ...)
				end
			end
		else
			function self:FireServer(v1, v2, v3, v4, v5, v6)
				writeFrame(globalBin, v1, v2, v3, v4, v5, v6)
			end
		end
	end

	if IS_SERVER then
		if spread and rateLimited then
			const function fireIfAllowed(player, ...)
				if rateLimitAllowed(self, player) then
					sig:Fire(player, ...)
				end
			end
			self._handle = function(buf, cursor, context, player)
				fireIfAllowed(player, payloadRead(buf, cursor, context))
				return context.readCursor
			end
		elseif spread then
			self._handle = function(buf, cursor, context, player)
				sig:Fire(player, payloadRead(buf, cursor, context))
				return context.readCursor
			end
		elseif packed and rateLimited then
			self._handle = function(buf, cursor, context, player)
				const value, nextCursor = payloadRead(buf, cursor, context)
				if rateLimitAllowed(self, player) then
					sig:Fire(player, table_unpack(value, 1, arity))
				end
				return nextCursor
			end
		elseif packed then
			self._handle = function(buf, cursor, context, player)
				const value, nextCursor = payloadRead(buf, cursor, context)
				sig:Fire(player, table_unpack(value, 1, arity))
				return nextCursor
			end
		elseif rateLimited then
			self._handle = function(buf, cursor, context, player)
				const value, nextCursor = payloadRead(buf, cursor, context)
				if rateLimitAllowed(self, player) then
					sig:Fire(player, value)
				end
				return nextCursor
			end
		else
			self._handle = function(buf, cursor, context, player)
				const value, nextCursor = payloadRead(buf, cursor, context)
				sig:Fire(player, value)
				return nextCursor
			end
		end
	elseif spread then
		self._handle = function(buf, cursor, context)
			sig:Fire(payloadRead(buf, cursor, context))
			return context.readCursor
		end
	elseif packed then
		self._handle = function(buf, cursor, context)
			const value, nextCursor = payloadRead(buf, cursor, context)
			sig:Fire(table_unpack(value, 1, arity))
			return nextCursor
		end
	else
		self._handle = function(buf, cursor, context)
			const value, nextCursor = payloadRead(buf, cursor, context)
			sig:Fire(value)
			return nextCursor
		end
	end

	return self
end

return module