--!native
--!optimize 2

const constants = require(script.Parent.constants)

const DEFAULT_SIZE = constants.DEFAULT_BIN_SIZE
const GROWTH_FACTOR = constants.BIN_GROWTH_FACTOR

const SLACK = 1

const buf_create = buffer.create
const buf_copy = buffer.copy
const buf_writeu8 = buffer.writeu8
const buf_writeu16 = buffer.writeu16
const buf_writeu32 = buffer.writeu32
const bit_lshift = bit32.lshift
const bit_countlz = bit32.countlz
const floor = math.floor

const function new(kind: string?)
	const unreliable = kind == "unreliable"
	return {
		buffer = buf_create(DEFAULT_SIZE + SLACK),
		cursor = 0,
		size = DEFAULT_SIZE,
		refs = {},
		refCount = 0,
		bools = {},
		amount = 0,
		value = 1,
		splits = if unreliable then {} else nil,
		splitCount = 0,
		chunkCursor = 0,
		chunkAmount = 0,
		chunkRefs = 0,
	}
end

-- alloc
const function reserve(bin, bytes: number)
	const needed = bin.cursor + bytes
	if needed <= bin.size then return end

	local newSize = bin.size
	while needed > newSize do
		newSize = floor(newSize * GROWTH_FACTOR) + 1
	end

	const newBuf = buf_create(newSize + SLACK)
	buf_copy(newBuf, 0, bin.buffer)
	bin.buffer = newBuf
	bin.size = newSize
end

const function tryWrite(bin, c, a0, r0, writer, v1, v2, v3, v4, v5, v6)
	const v0 = bin.value
	local attempts = 0
	while true do
		const ok, result = pcall(writer, bin.buffer, c, v1, bin, v2, v3, v4, v5, v6)
		if ok then
			return result
		end
		attempts += 1
		if attempts > 8 then
			error(result, 0)
		end
		bin.amount = a0
		bin.value = v0
		const r1 = bin.refCount
		if r1 > r0 then
			const refs = bin.refs
			for index = r0 + 1, r1 do
				refs[index] = nil
			end
			bin.refCount = r0
		end
		reserve(bin, (bin.size - bin.cursor) * 2 + 256)
	end
end

const function flushBools(bin)
	const value = bin.value
	if value == 1 then return end
	const amount = bin.amount + 1
	bin.bools[amount] = bit_lshift(value, bit_countlz(value) - 23) - 256
	bin.amount = amount
	bin.value = 1
end

const function flush(bin)
	bin.cursor = 0
	bin.refCount = 0
	bin.amount = 0
	bin.value = 1
	bin.splitCount = 0
	bin.chunkCursor = 0
	bin.chunkAmount = 0
	bin.chunkRefs = 0
end

const function snapshot(bin): buffer
	const out = buf_create(bin.cursor)
	buf_copy(out, 0, bin.buffer, 0, bin.cursor)
	return out
end

const function snapshotBools(bin, from: number?, to: number?): buffer?
	const start = if from == nil then 0 else from
	const finish = if to == nil then bin.amount else to
	const amount = finish - start
	if amount == 0 then
		return nil
	end

	const out = buf_create(amount)
	const bools = bin.bools
	local offset = 0
	while offset + 4 <= amount do
		const index = start + offset + 1
		buf_writeu32(
			out,
			offset,
			bools[index]
				+ bools[index + 1] * 256
				+ bools[index + 2] * 65536
				+ bools[index + 3] * 16777216
		)
		offset += 4
	end
	if amount - offset >= 2 then
		const index = start + offset + 1
		buf_writeu16(out, offset, bools[index] + bools[index + 1] * 256)
		offset += 2
	end
	if offset < amount then
		buf_writeu8(out, offset, bools[start + offset + 1])
	end
	return out
end

return {
	new = new,
	reserve = reserve,
	tryWrite = tryWrite,
	flushBools = flushBools,
	flush = flush,
	snapshot = snapshot,
	snapshotBools = snapshotBools,
}
