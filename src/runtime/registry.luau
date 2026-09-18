--!native
--!optimize 2

const bit_band = bit32.band
const bit_bor = bit32.bor
const bit_lshift = bit32.lshift
const bit_rshift = bit32.rshift

const ALL = {}
const MAX_ID = 65535
local nextId = 0
local byteMode: boolean?

const function register(entry: any)
	if byteMode ~= nil then
		error("bitnet: cannot register events or functions after networking has started", 2)
	end
	if nextId >= MAX_ID then
		error(`bitnet: cannot register more than {MAX_ID} events and functions`, 2)
	end

	nextId += 1
	const id = nextId
	const idSize = if id < 128 then 1 elseif id < 16384 then 2 else 3
	const first = if idSize == 1 then id else bit_bor(bit_band(id, 127), 128)
	const second = if idSize >= 2
		then bit_bor(bit_band(bit_rshift(id, 7), 127), if idSize == 3 then 128 else 0)
		else 0

	entry.id = id
	entry._idSize = idSize
	entry._idLow = bit_bor(first, bit_lshift(second, 8))
	entry._idHigh = if idSize == 3 then bit_rshift(id, 14) else 0
	ALL[id] = entry
	return entry
end

const function getByteMode(): boolean
	if byteMode == nil then
		byteMode = nextId < 255
	end
	return byteMode
end

const function getHeader(entry: any): (number, number, number)
	if byteMode == nil then
		byteMode = nextId < 255
	end
	if byteMode then
		return 1, entry.id, 0
	end
	return entry._idSize, entry._idLow, entry._idHigh
end

const function rateLimitAllowed(entry: any, player: Player): boolean
	const cfg = entry.rateLimit
	const state = entry.rateState[player]
	const now = os.clock()
	if not state then
		entry.rateState[player] = { tokens = cfg.calls - 1, lastRefill = now }
		return true
	end
	const elapsed = now - state.lastRefill
	state.tokens = math.min(cfg.calls, state.tokens + elapsed * (cfg.calls / cfg.per))
	state.lastRefill = now
	if state.tokens >= 1 then
		state.tokens -= 1
		return true
	end
	return false
end

return {
	ALL = ALL,
	register = register,
	getByteMode = getByteMode,
	getHeader = getHeader,
	rateLimitAllowed = rateLimitAllowed,
}