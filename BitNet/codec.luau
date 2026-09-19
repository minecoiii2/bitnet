--!native
--!optimize 2

const hash = require(script.Parent.libs.hash)
const constants = require(script.Parent.constants)
const playerIds = require(script.Parent.runtime.players)

const buf_writeu8 = buffer.writeu8
const buf_writeu16 = buffer.writeu16
const buf_writeu32 = buffer.writeu32
const buf_writei8 = buffer.writei8
const buf_writei16 = buffer.writei16
const buf_writei32 = buffer.writei32
const buf_writef32 = buffer.writef32
const buf_writef64 = buffer.writef64
const buf_writestring = buffer.writestring
const buf_readu8 = buffer.readu8
const buf_readu16 = buffer.readu16
const buf_readu32 = buffer.readu32
const buf_readi8 = buffer.readi8
const buf_readi16 = buffer.readi16
const buf_readi32 = buffer.readi32
const buf_readf32 = buffer.readf32
const buf_readf64 = buffer.readf64
const buf_readstring = buffer.readstring
const buf_copy = buffer.copy
const buf_len = buffer.len
const buf_create = buffer.create
const bit_band = bit32.band
const bit_bor = bit32.bor
const bit_rshift = bit32.rshift
const _typeof = typeof
const _floor = math.floor
const _clamp = math.clamp
const table_clone = table.clone
const table_create = table.create
const string_sub = string.sub
const string_format = string.format
const string_find = string.find
const string_gsub = string.gsub
const string_byte = string.byte
const _tonumber = tonumber

const MAX_SPREAD_ARITY = 6

const f24Scratch = buf_create(4)

const TAU = math.pi * 2
const ANGLE_SCALE = 65536 / TAU

const COMPRESS_DEFAULT_LEVEL = -2
const COMPRESS_MIN_BYTES = 128

const VALIDATE = constants.VALIDATE_INCOMING_TYPES
const MAX_DECOMPRESSED = constants.VALIDATE_MAX_DECOMPRESSED_BYTES

local EncodingService = nil
local CompressionAlgorithm = nil
do
	const ok, service = pcall(game.GetService, game, "EncodingService")
	if ok and service then
		EncodingService = service
		CompressionAlgorithm = Enum.CompressionAlgorithm.Zstd
	end
end

const function lengthSize(len: number): number
	return if len < 128
		then 1
		elseif len < 16384 then 2
		elseif len < 2097152 then 3
		elseif len < 268435456 then 4
		else 5
end

const function writeLength(b, c: number, len: number): number
	if len < 128 then
		buf_writeu8(b, c, len)
		return c + 1
	elseif len < 16384 then
		buf_writeu8(b, c, bit_bor(bit_band(len, 127), 128))
		buf_writeu8(b, c + 1, bit_rshift(len, 7))
		return c + 2
	elseif len < 2097152 then
		buf_writeu8(b, c, bit_bor(bit_band(len, 127), 128))
		buf_writeu8(b, c + 1, bit_bor(bit_band(bit_rshift(len, 7), 127), 128))
		buf_writeu8(b, c + 2, bit_rshift(len, 14))
		return c + 3
	elseif len < 268435456 then
		buf_writeu8(b, c, bit_bor(bit_band(len, 127), 128))
		buf_writeu8(b, c + 1, bit_bor(bit_band(bit_rshift(len, 7), 127), 128))
		buf_writeu8(b, c + 2, bit_bor(bit_band(bit_rshift(len, 14), 127), 128))
		buf_writeu8(b, c + 3, bit_rshift(len, 21))
		return c + 4
	end
	buf_writeu8(b, c, bit_bor(bit_band(len, 127), 128))
	buf_writeu8(b, c + 1, bit_bor(bit_band(bit_rshift(len, 7), 127), 128))
	buf_writeu8(b, c + 2, bit_bor(bit_band(bit_rshift(len, 14), 127), 128))
	buf_writeu8(b, c + 3, bit_bor(bit_band(bit_rshift(len, 21), 127), 128))
	buf_writeu8(b, c + 4, bit_rshift(len, 28))
	return c + 5
end

const function readLengthSlow(b, c: number): (number, number)
	const first = buf_readu8(b, c)
	const second = buf_readu8(b, c + 1)
	if second < 128 then
		return bit_band(first, 127) + second * 128, c + 2
	end

	const third = buf_readu8(b, c + 2)
	if third < 128 then
		return bit_band(first, 127) + bit_band(second, 127) * 128 + third * 16384, c + 3
	end

	const fourth = buf_readu8(b, c + 3)
	if fourth < 128 then
		return bit_band(first, 127)
			+ bit_band(second, 127) * 128
			+ bit_band(third, 127) * 16384
			+ fourth * 2097152, c + 4
	end

	const fifth = buf_readu8(b, c + 4)
	if fifth > 15 then
		error("bitnet: malformed length prefix")
	end
	return bit_band(first, 127)
		+ bit_band(second, 127) * 128
		+ bit_band(third, 127) * 16384
		+ bit_band(fourth, 127) * 2097152
		+ fifth * 268435456, c + 5
end

-- type checkers

const function checkUint(bits: number)
	const max = 2 ^ bits - 1
	return function(v)
		if type(v) ~= "number" then
			return false, "expected number, got " .. _typeof(v)
		end
		if v ~= v or v ~= _floor(v) then
			return false, "expected integer, got " .. tostring(v)
		end
		if v < 0 or v > max then
			return false, `u{bits} out of range [0, {max}]: {tostring(v)}`
		end
		return true
	end
end

const function checkInt(bits: number)
	const min = -(2 ^ (bits - 1))
	const max =  (2 ^ (bits - 1)) - 1
	return function(v)
		if type(v) ~= "number" then
			return false, "expected number, got " .. _typeof(v)
		end
		if v ~= v or v ~= _floor(v) then
			return false, "expected integer, got " .. tostring(v)
		end
		if v < min or v > max then
			return false, `i{bits} out of range [{min}, {max}]: {tostring(v)}`
		end
		return true
	end
end

const function checkNumber(v)
	if type(v) ~= "number" then
		return false, "expected number, got " .. _typeof(v)
	end
	return true
end

const function checkTypeof(expected: string)
	return function(v)
		if _typeof(v) ~= expected then
			return false, "expected " .. expected .. ", got " .. _typeof(v)
		end
		return true
	end
end

-- primitive compilers

const primitives = {}

primitives.u8 = {
	size = 1,
	check = checkUint(8),
	write = function(b, c, v) buf_writeu8(b, c, v); return c + 1 end,
	read  = function(b, c) return buf_readu8(b, c), c + 1 end,
	_writeMany = function(b, c, value, len)
		for i = 1, len do
			buf_writeu8(b, c, value[i])
			c += 1
		end
		return c
	end,
	_readMany = function(b, c, out, len)
		for i = 1, len do
			out[i] = buf_readu8(b, c)
			c += 1
		end
		return c
	end,
}
primitives.u16 = {
	size = 2,
	check = checkUint(16),
	write = function(b, c, v) buf_writeu16(b, c, v); return c + 2 end,
	read  = function(b, c) return buf_readu16(b, c), c + 2 end,
	_writeMany = function(b, c, value, len)
		for i = 1, len do
			buf_writeu16(b, c, value[i])
			c += 2
		end
		return c
	end,
	_readMany = function(b, c, out, len)
		for i = 1, len do
			out[i] = buf_readu16(b, c)
			c += 2
		end
		return c
	end,
}
primitives.u32 = {
	size = 4,
	check = checkUint(32),
	write = function(b, c, v) buf_writeu32(b, c, v); return c + 4 end,
	read  = function(b, c) return buf_readu32(b, c), c + 4 end,
	_writeMany = function(b, c, value, len)
		for i = 1, len do
			buf_writeu32(b, c, value[i])
			c += 4
		end
		return c
	end,
	_readMany = function(b, c, out, len)
		for i = 1, len do
			out[i] = buf_readu32(b, c)
			c += 4
		end
		return c
	end,
}
primitives.u24 = {
	size = 3,
	check = checkUint(24),
	write = function(b, c, v)
		buf_writeu16(b, c, bit_band(v, 65535))
		buf_writeu8(b, c + 2, bit_rshift(v, 16))
		return c + 3
	end,
	read = function(b, c)
		return buf_readu16(b, c) + buf_readu8(b, c + 2) * 65536, c + 3
	end,
	_writeMany = function(b, c, value, len)
		for i = 1, len do
			const v = value[i]
			buf_writeu16(b, c, bit_band(v, 65535))
			buf_writeu8(b, c + 2, bit_rshift(v, 16))
			c += 3
		end
		return c
	end,
	_readMany = function(b, c, out, len)
		for i = 1, len do
			out[i] = buf_readu16(b, c) + buf_readu8(b, c + 2) * 65536
			c += 3
		end
		return c
	end,
}

primitives.i8 = {
	size = 1,
	check = checkInt(8),
	write = function(b, c, v) buf_writei8(b, c, v); return c + 1 end,
	read  = function(b, c) return buf_readi8(b, c), c + 1 end,
	_writeMany = function(b, c, value, len)
		for i = 1, len do
			buf_writei8(b, c, value[i])
			c += 1
		end
		return c
	end,
	_readMany = function(b, c, out, len)
		for i = 1, len do
			out[i] = buf_readi8(b, c)
			c += 1
		end
		return c
	end,
}
primitives.i16 = {
	size = 2,
	check = checkInt(16),
	write = function(b, c, v) buf_writei16(b, c, v); return c + 2 end,
	read  = function(b, c) return buf_readi16(b, c), c + 2 end,
	_writeMany = function(b, c, value, len)
		for i = 1, len do
			buf_writei16(b, c, value[i])
			c += 2
		end
		return c
	end,
	_readMany = function(b, c, out, len)
		for i = 1, len do
			out[i] = buf_readi16(b, c)
			c += 2
		end
		return c
	end,
}
primitives.i32 = {
	size = 4,
	check = checkInt(32),
	write = function(b, c, v) buf_writei32(b, c, v); return c + 4 end,
	read  = function(b, c) return buf_readi32(b, c), c + 4 end,
	_writeMany = function(b, c, value, len)
		for i = 1, len do
			buf_writei32(b, c, value[i])
			c += 4
		end
		return c
	end,
	_readMany = function(b, c, out, len)
		for i = 1, len do
			out[i] = buf_readi32(b, c)
			c += 4
		end
		return c
	end,
}
primitives.i24 = {
	size = 3,
	check = checkInt(24),
	write = function(b, c, v)
		buf_writeu16(b, c, bit_band(v, 65535))
		buf_writei8(b, c + 2, _floor(v / 65536))
		return c + 3
	end,
	read = function(b, c)
		return buf_readu16(b, c) + buf_readi8(b, c + 2) * 65536, c + 3
	end,
	_writeMany = function(b, c, value, len)
		for i = 1, len do
			const v = value[i]
			buf_writeu16(b, c, bit_band(v, 65535))
			buf_writei8(b, c + 2, _floor(v / 65536))
			c += 3
		end
		return c
	end,
	_readMany = function(b, c, out, len)
		for i = 1, len do
			out[i] = buf_readu16(b, c) + buf_readi8(b, c + 2) * 65536
			c += 3
		end
		return c
	end,
}

primitives.f24 = {
	size = 3,
	check = checkNumber,
	write = function(b, c, v)
		buf_writef32(f24Scratch, 0, v)
		buf_copy(b, c, f24Scratch, 1, 3)
		return c + 3
	end,
	read = function(b, c)
		buf_writeu32(f24Scratch, 0, (buf_readu16(b, c) + buf_readu8(b, c + 2) * 65536) * 256)
		return buf_readf32(f24Scratch, 0), c + 3
	end,
	_writeMany = function(b, c, value, len)
		for i = 1, len do
			buf_writef32(f24Scratch, 0, value[i])
			buf_copy(b, c, f24Scratch, 1, 3)
			c += 3
		end
		return c
	end,
	_readMany = function(b, c, out, len)
		for i = 1, len do
			buf_writeu32(f24Scratch, 0, (buf_readu16(b, c) + buf_readu8(b, c + 2) * 65536) * 256)
			out[i] = buf_readf32(f24Scratch, 0)
			c += 3
		end
		return c
	end,
}

primitives.f32 = {
	size = 4,
	check = checkNumber,
	write = function(b, c, v) buf_writef32(b, c, v); return c + 4 end,
	read  = function(b, c) return buf_readf32(b, c), c + 4 end,
	_writeMany = function(b, c, value, len)
		for i = 1, len do
			buf_writef32(b, c, value[i])
			c += 4
		end
		return c
	end,
	_readMany = function(b, c, out, len)
		for i = 1, len do
			out[i] = buf_readf32(b, c)
			c += 4
		end
		return c
	end,
}
primitives.f64 = {
	size = 8,
	check = checkNumber,
	write = function(b, c, v) buf_writef64(b, c, v); return c + 8 end,
	read  = function(b, c) return buf_readf64(b, c), c + 8 end,
	_writeMany = function(b, c, value, len)
		for i = 1, len do
			buf_writef64(b, c, value[i])
			c += 8
		end
		return c
	end,
	_readMany = function(b, c, out, len)
		for i = 1, len do
			out[i] = buf_readf64(b, c)
			c += 8
		end
		return c
	end,
}

primitives.bool = {
	size = 0,
	check = checkTypeof("boolean"),
	write = function(b, c, v, context)
		const value = context.value * 2 + if v then 1 else 0
		if value >= 256 then
			const amount = context.amount + 1
			context.bools[amount] = value - 256
			context.amount = amount
			context.value = 1
		else
			context.value = value
		end
		return c
	end,
	read = function(b, c, context)
		local value = context.value
		if value == 256 then
			value = buf_readu8(context.bools, context.amount) * 2 + 1
			context.amount += 1
		end
		const result = value >= 256
		context.value = value % 256 * 2
		return result, c
	end,
}

primitives.string = {
	sizeOf = function(v)
		const len = #v
		--if len > 4294967295 then
		--	error("bitnet: string length exceeds u32", 2)
		--end
		return lengthSize(len) + len
	end,
	check = function(v)
		if type(v) ~= "string" then
			return false, "expected string, got " .. _typeof(v)
		end
		if #v > 4294967295 then
			return false, "string length exceeds u32"
		end
		return true
	end,
	write = function(b, c, v)
		const len = #v
		if len < 128 then
			buf_writeu8(b, c, len)
			c += 1
		else
			c = writeLength(b, c, len)
		end
		buf_writestring(b, c, v, len)
		return c + len
	end,
	read = function(b, c)
		local len = buf_readu8(b, c)
		if len < 128 then
			c += 1
		else
			len, c = readLengthSlow(b, c)
		end
		return buf_readstring(b, c, len), c + len
	end,
}

primitives.buffer = {
	sizeOf = function(v)
		const len = buf_len(v)
		--if len > 4294967295 then
		--	error("bitnet: buffer length exceeds u32", 2)
		--end
		return lengthSize(len) + len
	end,
	check = function(v)
		if type(v) ~= "buffer" then
			return false, "expected buffer, got " .. _typeof(v)
		end
		if buf_len(v) > 4294967295 then
			return false, "buffer length exceeds u32"
		end
		return true
	end,
	write = function(b, c, v)
		const len = buf_len(v)
		if len < 128 then
			buf_writeu8(b, c, len)
			c += 1
		else
			c = writeLength(b, c, len)
		end
		buf_copy(b, c, v)
		return c + len
	end,
	read = function(b, c)
		local len = buf_readu8(b, c)
		if len < 128 then
			c += 1
		else
			len, c = readLengthSlow(b, c)
		end
		const out = buf_create(len)
		buf_copy(out, 0, b, c, len)
		return out, c + len
	end,
}

primitives.vec2 = {
	size = 8,
	check = checkTypeof("Vector2"),
	write = function(b, c, v)
		buf_writef32(b, c,     v.X)
		buf_writef32(b, c + 4, v.Y)
		return c + 8
	end,
	read = function(b, c)
		return Vector2.new(
			buf_readf32(b, c),
			buf_readf32(b, c + 4)
		), c + 8
	end,
	_writeMany = function(b, c, value, len)
		for i = 1, len do
			const v = value[i]
			buf_writef32(b, c, v.X)
			buf_writef32(b, c + 4, v.Y)
			c += 8
		end
		return c
	end,
	_readMany = function(b, c, out, len)
		for i = 1, len do
			out[i] = Vector2.new(buf_readf32(b, c), buf_readf32(b, c + 4))
			c += 8
		end
		return c
	end,
}

primitives.vec3 = {
	size = 12,
	check = checkTypeof("Vector3"),
	write = function(b, c, v)
		buf_writef32(b, c,     v.X)
		buf_writef32(b, c + 4, v.Y)
		buf_writef32(b, c + 8, v.Z)
		return c + 12
	end,
	read = function(b, c)
		return Vector3.new(
			buf_readf32(b, c),
			buf_readf32(b, c + 4),
			buf_readf32(b, c + 8)
		), c + 12
	end,
	_writeMany = function(b, c, value, len)
		for i = 1, len do
			const v = value[i]
			buf_writef32(b, c, v.X)
			buf_writef32(b, c + 4, v.Y)
			buf_writef32(b, c + 8, v.Z)
			c += 12
		end
		return c
	end,
	_readMany = function(b, c, out, len)
		for i = 1, len do
			out[i] = Vector3.new(buf_readf32(b, c), buf_readf32(b, c + 4), buf_readf32(b, c + 8))
			c += 12
		end
		return c
	end,
}

primitives.color3 = {
	size = 3,
	check = checkTypeof("Color3"),
	write = function(b, c, v: Color3)
		buf_writeu8(b, c,     _floor(_clamp(v.R, 0, 1) * 255 + 0.5))
		buf_writeu8(b, c + 1, _floor(_clamp(v.G, 0, 1) * 255 + 0.5))
		buf_writeu8(b, c + 2, _floor(_clamp(v.B, 0, 1) * 255 + 0.5))
		return c + 3
	end,
	read = function(b, c)
		return Color3.fromRGB(
			buf_readu8(b, c),
			buf_readu8(b, c + 1),
			buf_readu8(b, c + 2)
		), c + 3
	end,
}

primitives.cframelong = {
	size = 24,
	check = checkTypeof("CFrame"),
	write = function(b, c, v: CFrame)
		buf_writef32(b, c,      v.X)
		buf_writef32(b, c + 4,  v.Y)
		buf_writef32(b, c + 8,  v.Z)
		const rx, ry, rz = v:ToOrientation()
		buf_writef32(b, c + 12, rx)
		buf_writef32(b, c + 16, ry)
		buf_writef32(b, c + 20, rz)
		return c + 24
	end,
	read = function(b, c)
		const x  = buf_readf32(b, c)
		const y  = buf_readf32(b, c + 4)
		const z  = buf_readf32(b, c + 8)
		const rx = buf_readf32(b, c + 12)
		const ry = buf_readf32(b, c + 16)
		const rz = buf_readf32(b, c + 20)
		return CFrame.fromOrientation(rx, ry, rz) + Vector3.new(x, y, z), c + 24
	end,
}

primitives.cframe = {
	size = 18,
	check = checkTypeof("CFrame"),
	write = function(b, c, v: CFrame)
		buf_writef32(b, c,     v.X)
		buf_writef32(b, c + 4, v.Y)
		buf_writef32(b, c + 8, v.Z)
		const rx, ry, rz = v:ToOrientation()
		buf_writeu16(b, c + 12, bit_band(rx % TAU * ANGLE_SCALE + 0.5, 65535))
		buf_writeu16(b, c + 14, bit_band(ry % TAU * ANGLE_SCALE + 0.5, 65535))
		buf_writeu16(b, c + 16, bit_band(rz % TAU * ANGLE_SCALE + 0.5, 65535))
		return c + 18
	end,
	read = function(b, c)
		const x = buf_readf32(b, c)
		const y = buf_readf32(b, c + 4)
		const z = buf_readf32(b, c + 8)
		return CFrame.fromOrientation(
			buf_readu16(b, c + 12) / ANGLE_SCALE,
			buf_readu16(b, c + 14) / ANGLE_SCALE,
			buf_readu16(b, c + 16) / ANGLE_SCALE
		) + Vector3.new(x, y, z), c + 18
	end,
}

primitives.brickcolor = {
	size = 2,
	check = checkTypeof("BrickColor"),
	write = function(b, c, v: BrickColor)
		buf_writeu16(b, c, v.Number)
		return c + 2
	end,
	read = function(b, c)
		return BrickColor.new(buf_readu16(b, c)), c + 2
	end,
}

primitives.numberrange = {
	size = 8,
	check = checkTypeof("NumberRange"),
	write = function(b, c, v: NumberRange)
		buf_writef32(b, c,     v.Min)
		buf_writef32(b, c + 4, v.Max)
		return c + 8
	end,
	read = function(b, c)
		return NumberRange.new(buf_readf32(b, c), buf_readf32(b, c + 4)), c + 8
	end,
}

const function checkUDimParts(scale: number, offset: number): (boolean, string?)
	if scale ~= scale or scale > 32.767 or scale < -32.768 then
		return false, `Scale out of range [-32.768, 32.767]: {tostring(scale)}`
	end
	if offset ~= _floor(offset) or offset > 32767 or offset < -32768 then
		return false, `Offset must be a whole number in [-32768, 32767]: {tostring(offset)}`
	end
	return true
end

primitives.udim = {
	size = 4,
	check = function(v)
		if _typeof(v) ~= "UDim" then
			return false, "expected UDim, got " .. _typeof(v)
		end
		return checkUDimParts(v.Scale, v.Offset)
	end,
	write = function(b, c, v: UDim)
		buf_writei16(b, c,     _floor(v.Scale * 1000 + 0.5))
		buf_writei16(b, c + 2, v.Offset)
		return c + 4
	end,
	read = function(b, c)
		return UDim.new(buf_readi16(b, c) / 1000, buf_readi16(b, c + 2)), c + 4
	end,
}

primitives.udim2 = {
	size = 8,
	check = function(v)
		if _typeof(v) ~= "UDim2" then
			return false, "expected UDim2, got " .. _typeof(v)
		end
		const x = v.X
		const xok, xerr = checkUDimParts(x.Scale, x.Offset)
		if not xok then return false, "X: " .. xerr end
		const y = v.Y
		const yok, yerr = checkUDimParts(y.Scale, y.Offset)
		if not yok then return false, "Y: " .. yerr end
		return true
	end,
	write = function(b, c, v: UDim2)
		const x = v.X
		const y = v.Y
		buf_writei16(b, c,     _floor(x.Scale * 1000 + 0.5))
		buf_writei16(b, c + 2, x.Offset)
		buf_writei16(b, c + 4, _floor(y.Scale * 1000 + 0.5))
		buf_writei16(b, c + 6, y.Offset)
		return c + 8
	end,
	read = function(b, c)
		return UDim2.new(
			buf_readi16(b, c) / 1000,
			buf_readi16(b, c + 2),
			buf_readi16(b, c + 4) / 1000,
			buf_readi16(b, c + 6)
		), c + 8
	end,
}

const function numberSequenceSize(keypoints, n: number): number
	local previous = -1
	for i = 1, n do
		const k = keypoints[i]
		if k.Value < 0 or k.Value > 1 or k.Envelope < 0 or k.Envelope > 1 then
			return 1 + n * 12
		end
		const t = _floor(k.Time * 65535 + 0.5)
		if t <= previous then
			return 1 + n * 12
		end
		previous = t
	end
	return 1 + n * 4
end

primitives.numbersequence = {
	_costly = true,
	sizeOf = function(v: NumberSequence)
		const keypoints = v.Keypoints
		return numberSequenceSize(keypoints, #keypoints)
	end,
	check = function(v)
		if _typeof(v) ~= "NumberSequence" then
			return false, "expected NumberSequence, got " .. _typeof(v)
		end
		if #v.Keypoints > 255 then
			return false, "NumberSequence has more than 255 keypoints"
		end
		return true
	end,
	write = function(b, c, v: NumberSequence, context)
		const keypoints = v.Keypoints
		const n = #keypoints
		const start = c
		buf_writeu8(b, c, n)
		c += 1

		local compact = true
		local previous = -1
		for i = 1, n do
			const k = keypoints[i]
			const value = k.Value
			const envelope = k.Envelope
			const t = _floor(k.Time * 65535 + 0.5)
			if value < 0 or value > 1 or envelope < 0 or envelope > 1 or t <= previous then
				compact = false
				break
			end
			previous = t
			buf_writeu16(b, c,    t)
			buf_writeu8(b, c + 2, _floor(value * 255 + 0.5))
			buf_writeu8(b, c + 3, _floor(envelope * 255 + 0.5))
			c += 4
		end

		if not compact then
			c = start + 1
			for i = 1, n do
				const k = keypoints[i]
				buf_writef32(b, c,     k.Time)
				buf_writef32(b, c + 4, k.Value)
				buf_writef32(b, c + 8, k.Envelope)
				c += 12
			end
		end

		const bits = context.value * 2 + if compact then 1 else 0
		if bits >= 256 then
			const amount = context.amount + 1
			context.bools[amount] = bits - 256
			context.amount = amount
			context.value = 1
		else
			context.value = bits
		end
		return c
	end,
	read = function(b, c, context)
		local bits = context.value
		if bits == 256 then
			bits = buf_readu8(context.bools, context.amount) * 2 + 1
			context.amount += 1
		end
		const compact = bits >= 256
		context.value = bits % 256 * 2

		const n = buf_readu8(b, c)
		c += 1
		const keypoints = table_create(n)
		if compact then
			for i = 1, n do
				keypoints[i] = NumberSequenceKeypoint.new(
					buf_readu16(b, c) / 65535,
					buf_readu8(b, c + 2) / 255,
					buf_readu8(b, c + 3) / 255
				)
				c += 4
			end
			return NumberSequence.new(keypoints), c
		end
		for i = 1, n do
			keypoints[i] = NumberSequenceKeypoint.new(
				buf_readf32(b, c),
				buf_readf32(b, c + 4),
				buf_readf32(b, c + 8)
			)
			c += 12
		end
		return NumberSequence.new(keypoints), c
	end,
}

primitives.colorsequence = {
	sizeOf = function(v: ColorSequence)
		return 1 + #v.Keypoints * 7
	end,
	check = function(v)
		if _typeof(v) ~= "ColorSequence" then
			return false, "expected ColorSequence, got " .. _typeof(v)
		end
		if #v.Keypoints > 255 then
			return false, "ColorSequence has more than 255 keypoints"
		end
		return true
	end,
	write = function(b, c, v: ColorSequence)
		const keypoints = v.Keypoints
		const n = #keypoints
		buf_writeu8(b, c, n)
		c += 1
		for i = 1, n do
			const k = keypoints[i]
			const col = k.Value
			buf_writef32(b, c, k.Time)
			buf_writeu8(b, c + 4, _floor(_clamp(col.R, 0, 1) * 255 + 0.5))
			buf_writeu8(b, c + 5, _floor(_clamp(col.G, 0, 1) * 255 + 0.5))
			buf_writeu8(b, c + 6, _floor(_clamp(col.B, 0, 1) * 255 + 0.5))
			c += 7
		end
		return c
	end,
	read = function(b, c)
		const n = buf_readu8(b, c)
		c += 1
		const keypoints = table_create(n)
		for i = 1, n do
			keypoints[i] = ColorSequenceKeypoint.new(
				buf_readf32(b, c),
				Color3.fromRGB(buf_readu8(b, c + 4), buf_readu8(b, c + 5), buf_readu8(b, c + 6))
			)
			c += 7
		end
		return ColorSequence.new(keypoints), c
	end,
}

primitives.uuid = {
	size = 16,
	check = function(v)
		if type(v) ~= "string" then
			return false, "expected uuid string, got " .. _typeof(v)
		end
		if #v ~= 36 then
			return false, `uuid must be 36 characters and unbraced, got {#v}`
		end
		if string_byte(v, 9) ~= 45 or string_byte(v, 14) ~= 45
			or string_byte(v, 19) ~= 45 or string_byte(v, 24) ~= 45 then
			return false, `uuid hyphens must sit at 9, 14, 19 and 24: {v}`
		end
		if string_find(v, "[^0-9a-f%-]") then
			return false, `uuid must be lowercase hex, got {v}`
		end
		local _, hyphens = string_gsub(v, "%-", "")
		if hyphens ~= 4 then
			return false, `uuid must contain exactly 4 hyphens, got {hyphens}`
		end
		return true
	end,
	write = function(b, c, v: string)
		buf_writeu32(b, c,      _tonumber(string_sub(v, 1, 8), 16))
		buf_writeu16(b, c + 4,  _tonumber(string_sub(v, 10, 13), 16))
		buf_writeu16(b, c + 6,  _tonumber(string_sub(v, 15, 18), 16))
		buf_writeu16(b, c + 8,  _tonumber(string_sub(v, 20, 23), 16))
		buf_writeu16(b, c + 10, _tonumber(string_sub(v, 25, 28), 16))
		buf_writeu32(b, c + 12, _tonumber(string_sub(v, 29, 36), 16))
		return c + 16
	end,
	read = function(b, c)
		return string_format("%08x-%04x-%04x-%04x-%04x%08x",
			buf_readu32(b, c),
			buf_readu16(b, c + 4),
			buf_readu16(b, c + 6),
			buf_readu16(b, c + 8),
			buf_readu16(b, c + 10),
			buf_readu32(b, c + 12)
		), c + 16
	end,
}

primitives.nothing = {
	size = 0,
	check = function(v)
		if v ~= nil then return false, "expected nil, got " .. _typeof(v) end
		return true
	end,
	write = function(b, c, v) return c end,
	read  = function(b, c) return nil, c end,
}

const boolWrite = primitives.bool.write
const boolRead = primitives.bool.read

primitives.ref = {
	size = 0,
	check = function(v)
		const t = type(v)
		if t == "function" or t == "thread" then
			return false, "ref cannot carry " .. t .. " values (RemoteEvent can't serialize)"
		end
		return true
	end,
	write = function(b, c, v, context)
		if not context then
			error("bitnet: types.ref written outside a codec context")
		end
		const count = context.refCount + 1
		context.refCount = count
		if v then
			context.refs[count] = v
			return c
		end
		context.refs[count] = false
		return boolWrite(b, c, v == false, context)
	end,
	read = function(b, c, context)
		const count = context.refCount + 1
		context.refCount = count
		const v = context.refs[count]
		if v == false then
			const isFalse = boolRead(b, c, context)
			return (if isFalse then false else nil), c
		end
		return v, c
	end,
}

const playersById = playerIds.byId
const playerIdFor = playerIds.idFor

primitives.player = {
	size = 1,
	check = function(v)
		if v == nil then return true end
		if _typeof(v) ~= "Instance" then
			return false, "expected Player, got " .. _typeof(v)
		end
		if not v:IsA("Player") then
			return false, "expected Player, got " .. v.ClassName
		end
		return true
	end,
	write = function(b, c, v)
		buf_writeu8(b, c, if v then playerIdFor(v) else 0)
		return c + 1
	end,
	read = function(b, c)
		return playersById[buf_readu8(b, c)], c + 1
	end,
	_writeMany = function(b, c, value, len)
		for i = 1, len do
			const v = value[i]
			buf_writeu8(b, c, if v then playerIdFor(v) else 0)
			c += 1
		end
		return c
	end,
	_readMany = function(b, c, out, len)
		for i = 1, len do
			out[i] = playersById[buf_readu8(b, c)]
			c += 1
		end
		return c
	end,
}

primitives.number = primitives.f64
primitives.unknown = primitives.ref

primitives.bool._sideChannel = true
primitives.ref._sideChannel = true
primitives.numbersequence._sideChannel = true
for _, t in primitives do
	if t._sideChannel == nil then
		t._sideChannel = false
	end
end


const VANISHED_REF_ALLOWANCE = 1024
const EMPTY_ELEMENT_ALLOWANCE = 1024
const AUTO_MAX_DEPTH = 128
const ZSTD_MAGIC = 0xFD2FB528

primitives.bool._minBits = 1
primitives.ref._minRefs = 1

const function fail(message: string)
	error(message, 0)
end

const function cleanError(err): string
	local message = tostring(err)
	message = string_gsub(message, "^.-:%d+: ", "")
	message = string_gsub(message, "^bitnet: ", "")
	return message
end

const function minWire(t): (number, number, number)
	local bytes = t._minBytes
	if bytes == nil then
		bytes = if t.size then t.size else 1
	end
	return bytes, t._minBits or 0, t._minRefs or 0
end

const function readCount(b, c: number): (number, number)
	const count = buf_readu8(b, c)
	if count < 128 then
		return count, c + 1
	end
	return readLengthSlow(b, c)
end

const function checkCount(count: number, minBytes: number, minBits: number, minRefs: number, b, c: number, context, what: string)
	if count == 0 then
		return
	end
	if minBytes > 0 then
		const left = buf_len(b) - c
		if count * minBytes > left then
			fail(`{what} of {count} needs at least {count * minBytes} bytes, {left} left`)
		end
	elseif minBits > 0 then
		const left = (buf_len(context.bools) - context.amount) * 8 + 8
		if count * minBits > left then
			fail(`{what} of {count} needs at least {count * minBits} booleans, at most {left} left`)
		end
	elseif minRefs > 0 then
		local room = context.refRoom
		if room == nil then
			room = VANISHED_REF_ALLOWANCE
			for _ in context.refs do
				room += 1
			end
			context.refRoom = room
		end
		const left = room - context.refCount
		if count * minRefs > left then
			fail(`{what} of {count} needs at least {count * minRefs} refs, at most {left} left`)
		end
	else
		const left = if context.emptyRoom == nil then EMPTY_ELEMENT_ALLOWANCE else context.emptyRoom
		if count > left then
			fail(`{what} of {count} empty elements exceeds the {left} left for this batch`)
		end
		context.emptyRoom = left - count
	end
end

const function checkMapCount(count: number)
	if count > 16383 then
		fail(`map of {count} entries exceeds the 16383 limit`)
	end
end

const function strictBool(b, c, context)
	local value = context.value
	if value == 256 then
		const amount = context.amount
		if amount >= buf_len(context.bools) then
			fail("boolean side channel ran out")
		end
		value = buf_readu8(context.bools, amount) * 2 + 1
		context.amount = amount + 1
	end
	context.value = value % 256 * 2
	return value >= 256, c
end

const function nonFinite(context, what: string, shown: string)
	const entries = context.entries
	const entry = if entries then entries[context.frameId] else nil
	if (entry and entry._acceptNonFinite) or context.skipNonFinite then
		return
	end
	context.valueFault = true
	fail(`{what} is not finite ({shown})`)
end

const function zstdContentSize(b, c: number, finish: number): number
	local total = 0
	while c < finish do
		if finish - c < 6 or buf_readu32(b, c) ~= ZSTD_MAGIC then
			fail("compressed payload is not a zstd frame")
		end
		const descriptor = buf_readu8(b, c + 4)
		c += 5
		if bit_band(descriptor, 3) ~= 0 then
			fail("zstd dictionaries are not supported")
		end
		const singleSegment = bit_band(descriptor, 32) ~= 0
		if not singleSegment then
			c += 1
		end
		const sizeFlag = bit_rshift(descriptor, 6)
		if sizeFlag == 0 then
			if not singleSegment then
				fail("zstd frame does not declare its content size")
			end
			total += buf_readu8(b, c)
			c += 1
		elseif sizeFlag == 1 then
			total += buf_readu16(b, c) + 256
			c += 2
		elseif sizeFlag == 2 then
			total += buf_readu32(b, c)
			c += 4
		else
			total += buf_readu32(b, c) + buf_readu32(b, c + 4) * 4294967296
			c += 8
		end
		local last = false
		while not last do
			if finish - c < 3 then
				fail("zstd frame is truncated")
			end
			const header = buf_readu16(b, c) + buf_readu8(b, c + 2) * 65536
			c += 3
			last = header % 2 == 1
			const blockType = bit_band(bit_rshift(header, 1), 3)
			if blockType == 3 then
				fail("zstd block type is reserved")
			end
			c += if blockType == 1 then 1 else bit_rshift(header, 3)
		end
		if bit_band(descriptor, 4) ~= 0 then
			c += 4
		end
	end
	if c ~= finish then
		fail("zstd frame overruns its payload")
	end
	return total
end

if VALIDATE then
	primitives.bool.read = strictBool

	primitives.ref.read = function(b, c, context)
		const count = context.refCount + 1
		context.refCount = count
		const v = context.refs[count]
		if v == false then
			return (if strictBool(b, c, context) then false else nil), c
		end
		return v, c
	end

	primitives.string.read = function(b, c)
		local len = buf_readu8(b, c)
		if len < 128 then
			c += 1
		else
			len, c = readLengthSlow(b, c)
		end
		const left = buf_len(b) - c
		if len > left then
			fail(`string of {len} bytes, {left} left`)
		end
		return buf_readstring(b, c, len), c + len
	end

	primitives.buffer.read = function(b, c)
		local len = buf_readu8(b, c)
		if len < 128 then
			c += 1
		else
			len, c = readLengthSlow(b, c)
		end
		const left = buf_len(b) - c
		if len > left then
			fail(`buffer of {len} bytes, {left} left`)
		end
		const out = buf_create(len)
		buf_copy(out, 0, b, c, len)
		return out, c + len
	end

	primitives.f24.read = function(b, c, context)
		buf_writeu32(f24Scratch, 0, (buf_readu16(b, c) + buf_readu8(b, c + 2) * 65536) * 256)
		const v = buf_readf32(f24Scratch, 0)
		if v - v ~= 0 then
			nonFinite(context, "f24", tostring(v))
		end
		return v, c + 3
	end
	primitives.f24._readMany = function(b, c, out, len, context)
		for i = 1, len do
			buf_writeu32(f24Scratch, 0, (buf_readu16(b, c) + buf_readu8(b, c + 2) * 65536) * 256)
			const v = buf_readf32(f24Scratch, 0)
			if v - v ~= 0 then
				nonFinite(context, "f24", tostring(v))
			end
			out[i] = v
			c += 3
		end
		return c
	end

	primitives.f32.read = function(b, c, context)
		const v = buf_readf32(b, c)
		if v - v ~= 0 then
			nonFinite(context, "f32", tostring(v))
		end
		return v, c + 4
	end
	primitives.f32._readMany = function(b, c, out, len, context)
		for i = 1, len do
			const v = buf_readf32(b, c)
			if v - v ~= 0 then
				nonFinite(context, "f32", tostring(v))
			end
			out[i] = v
			c += 4
		end
		return c
	end

	primitives.f64.read = function(b, c, context)
		const v = buf_readf64(b, c)
		if v - v ~= 0 then
			nonFinite(context, "f64", tostring(v))
		end
		return v, c + 8
	end
	primitives.f64._readMany = function(b, c, out, len, context)
		for i = 1, len do
			const v = buf_readf64(b, c)
			if v - v ~= 0 then
				nonFinite(context, "f64", tostring(v))
			end
			out[i] = v
			c += 8
		end
		return c
	end

	primitives.vec2.read = function(b, c, context)
		const x = buf_readf32(b, c)
		const y = buf_readf32(b, c + 4)
		if (x - x) + (y - y) ~= 0 then
			nonFinite(context, "Vector2", `{x}, {y}`)
		end
		return Vector2.new(x, y), c + 8
	end
	primitives.vec2._readMany = function(b, c, out, len, context)
		for i = 1, len do
			const x = buf_readf32(b, c)
			const y = buf_readf32(b, c + 4)
			if (x - x) + (y - y) ~= 0 then
				nonFinite(context, "Vector2", `{x}, {y}`)
			end
			out[i] = Vector2.new(x, y)
			c += 8
		end
		return c
	end

	primitives.vec3.read = function(b, c, context)
		const x = buf_readf32(b, c)
		const y = buf_readf32(b, c + 4)
		const z = buf_readf32(b, c + 8)
		if (x - x) + (y - y) + (z - z) ~= 0 then
			nonFinite(context, "Vector3", `{x}, {y}, {z}`)
		end
		return Vector3.new(x, y, z), c + 12
	end
	primitives.vec3._readMany = function(b, c, out, len, context)
		for i = 1, len do
			const x = buf_readf32(b, c)
			const y = buf_readf32(b, c + 4)
			const z = buf_readf32(b, c + 8)
			if (x - x) + (y - y) + (z - z) ~= 0 then
				nonFinite(context, "Vector3", `{x}, {y}, {z}`)
			end
			out[i] = Vector3.new(x, y, z)
			c += 12
		end
		return c
	end

	primitives.cframe.read = function(b, c, context)
		const x = buf_readf32(b, c)
		const y = buf_readf32(b, c + 4)
		const z = buf_readf32(b, c + 8)
		if (x - x) + (y - y) + (z - z) ~= 0 then
			nonFinite(context, "CFrame position", `{x}, {y}, {z}`)
		end
		return CFrame.fromOrientation(
			buf_readu16(b, c + 12) / ANGLE_SCALE,
			buf_readu16(b, c + 14) / ANGLE_SCALE,
			buf_readu16(b, c + 16) / ANGLE_SCALE
		) + Vector3.new(x, y, z), c + 18
	end

	primitives.cframelong.read = function(b, c, context)
		const x = buf_readf32(b, c)
		const y = buf_readf32(b, c + 4)
		const z = buf_readf32(b, c + 8)
		const rx = buf_readf32(b, c + 12)
		const ry = buf_readf32(b, c + 16)
		const rz = buf_readf32(b, c + 20)
		if (x - x) + (y - y) + (z - z) + (rx - rx) + (ry - ry) + (rz - rz) ~= 0 then
			nonFinite(context, "CFrame", `{x}, {y}, {z}, {rx}, {ry}, {rz}`)
		end
		return CFrame.fromOrientation(rx, ry, rz) + Vector3.new(x, y, z), c + 24
	end

	primitives.numberrange.read = function(b, c, context)
		const min = buf_readf32(b, c)
		const max = buf_readf32(b, c + 4)
		if (min - min) + (max - max) ~= 0 then
			nonFinite(context, "NumberRange", `{min}, {max}`)
		end
		return NumberRange.new(min, max), c + 8
	end

	primitives.numbersequence.read = function(b, c, context)
		const compact = strictBool(b, c, context)
		const n = buf_readu8(b, c)
		c += 1
		const keypoints = table_create(n)
		if compact then
			for i = 1, n do
				keypoints[i] = NumberSequenceKeypoint.new(
					buf_readu16(b, c) / 65535,
					buf_readu8(b, c + 2) / 255,
					buf_readu8(b, c + 3) / 255
				)
				c += 4
			end
			return NumberSequence.new(keypoints), c
		end
		for i = 1, n do
			const t = buf_readf32(b, c)
			const v = buf_readf32(b, c + 4)
			const e = buf_readf32(b, c + 8)
			if (t - t) + (v - v) + (e - e) ~= 0 then
				nonFinite(context, `NumberSequence keypoint {i}`, `{t}, {v}, {e}`)
			end
			keypoints[i] = NumberSequenceKeypoint.new(t, v, e)
			c += 12
		end
		return NumberSequence.new(keypoints), c
	end

	primitives.colorsequence.read = function(b, c, context)
		const n = buf_readu8(b, c)
		c += 1
		const keypoints = table_create(n)
		for i = 1, n do
			const t = buf_readf32(b, c)
			if t - t ~= 0 then
				nonFinite(context, `ColorSequence keypoint {i} time`, tostring(t))
			end
			keypoints[i] = ColorSequenceKeypoint.new(
				t,
				Color3.fromRGB(buf_readu8(b, c + 4), buf_readu8(b, c + 5), buf_readu8(b, c + 6))
			)
			c += 7
		end
		return ColorSequence.new(keypoints), c
	end
end

const function attempt(t, b, c: number, context)
	const refCount, amount, value = context.refCount, context.amount, context.value
	const ok, result, nextCursor = pcall(t.read, b, c, context)
	if ok then
		return true, result, nextCursor
	end
	context.refCount = refCount
	context.amount = amount
	context.value = value
	return false, cleanError(result), c
end

const function leafReason(t, b, c: number, context): string?
	const ok, reason = attempt(t, b, c, context)
	if ok then
		return nil
	end
	if t.size and t.size > 0 and string_find(reason, "out of bounds", 1, true) then
		return `needs {t.size} bytes, {buf_len(b) - c} left`
	end
	return reason
end

local locate

function locate(t, b, c: number, context, path: string): (string, string?)
	const kind = t._kind
	const start, refCount, amount, value = c, context.refCount, context.amount, context.value
	if kind == "struct" or kind == "tuple" then
		const types = t._types
		const keys = t._keys
		for i = 1, #types do
			const child = types[i]
			const ok, _, nextCursor = attempt(child, b, c, context)
			if not ok then
				local label
				if keys then
					label = if path == "" then keys[i] else `{path}.{keys[i]}`
				else
					label = if path == "" then `arg {i}` else `{path}[{i}]`
				end
				return locate(child, b, c, context, label)
			end
			c = nextCursor
		end
	elseif kind == "optional" then
		const ok, present = pcall(strictBool, b, c, context)
		if not ok then
			return path, cleanError(present)
		end
		if present then
			return locate(t._inner, b, c, context, path)
		end
		return path, nil
	elseif kind == "array" or kind == "map" then
		const ok, count, first = pcall(readCount, b, c)
		if not ok then
			return path, cleanError(count)
		end
		if kind == "map" then
			const underLimit, tooMany = pcall(checkMapCount, count)
			if not underLimit then
				return path, cleanError(tooMany)
			end
		end
		local minBytes, minBits, minRefs
		if kind == "array" then
			minBytes, minBits, minRefs = minWire(t._elem)
		else
			const kb, kbits, krefs = minWire(t._key)
			const vb, vbits, vrefs = minWire(t._value)
			minBytes, minBits, minRefs = kb + vb, kbits + vbits, krefs + vrefs
		end
		const fits, why = pcall(checkCount, count, minBytes, minBits, minRefs, b, first, context, kind)
		if not fits then
			return path, cleanError(why)
		end
		c = first
		for i = 1, count do
			if kind == "array" then
				const elemOk, _, nextCursor = attempt(t._elem, b, c, context)
				if not elemOk then
					return locate(t._elem, b, c, context, `{path}[{i}]`)
				end
				c = nextCursor
			else
				const keyOk, key, afterKey = attempt(t._key, b, c, context)
				if not keyOk then
					return locate(t._key, b, c, context, if path == "" then `key #{i}` else `{path} key #{i}`)
				end
				const valueOk, _, afterValue = attempt(t._value, b, afterKey, context)
				if not valueOk then
					return locate(t._value, b, afterKey, context, `{path}[{tostring(key)}]`)
				end
				c = afterValue
			end
		end
	end
	context.refCount = refCount
	context.amount = amount
	context.value = value
	return path, leafReason(t, b, start, context)
end

-- higher level compilers

const function compileStruct(fields: { [string]: any })
	const sorted = {}
	const seenHashes: {string} = {}
	for key, t in fields do
		const h = hash(key)
		if seenHashes[h] then
			error(`bitnet: hash collision in struct between {seenHashes[h]} and {key}`)
		end
		seenHashes[h] = key
		table.insert(sorted, { key = key, type = t, hash = h })
	end
	table.sort(sorted, function(a, b)
		return a.hash < b.hash
	end)

	const n = #sorted
	const keys = table.create(n)
	const writers = table.create(n)
	const readers = table.create(n)
	const fieldTypes = table.create(n)
	const fieldChecks = table.create(n)
	const template = {}

	local totalSize = 0
	local allFixed = true
	local costly = false
	local sideChannel = false
	local minBytes, minBits, minRefs = 0, 0, 0

	for i, f in sorted do
		keys[i] = f.key
		template[f.key] = false
		writers[i] = f.type.write
		readers[i] = f.type.read
		fieldTypes[i] = f.type
		fieldChecks[i] = f.type.check
		if f.type._costly then
			costly = true
		end
		if f.type.size then
			totalSize += f.type.size
		else
			allFixed = false
		end
		if f.type._sideChannel ~= false then
			sideChannel = true
		end
		const fb, fbits, frefs = minWire(f.type)
		minBytes += fb
		minBits += fbits
		minRefs += frefs
	end

	const function writeFn(b, c, value, context)
		for i = 1, n do
			c = writers[i](b, c, value[keys[i]], context)
		end
		return c
	end

	const function readFn(b, c, context)
		const out = table_clone(template)
		for i = 1, n do
			out[keys[i]], c = readers[i](b, c, context)
		end
		return out, c
	end

	const function checkFn(value)
		if type(value) ~= "table" then
			return false, "expected table, got " .. _typeof(value)
		end
		for i = 1, n do
			const key = keys[i]
			const ok, err = fieldChecks[i](value[key])
			if not ok then return false, "field " .. key .. ": " .. err end
		end
		return true
	end

	local compiled
	if allFixed then
		compiled = { size = totalSize, check = checkFn, write = writeFn, read = readFn }
	else
		compiled = {
			_costly = costly,
			sizeOf = function(value)
				local s = 0
				for i = 1, n do
					const t = fieldTypes[i]
					s += t.size or t.sizeOf(value[keys[i]])
				end
				return s
			end,
			check = checkFn,
			write = writeFn,
			read = readFn,
		}
	end
	compiled._kind = "struct"
	compiled._sideChannel = sideChannel
	compiled._keys = keys
	compiled._types = fieldTypes
	compiled._minBytes = minBytes
	compiled._minBits = minBits
	compiled._minRefs = minRefs
	return compiled
end

const function compileArray(elementType)
	const elemWrite = elementType.write
	const elemRead = elementType.read
	const elemCheck = elementType.check
	const elemSize = elementType.size
	const elemSizeOf = elementType.sizeOf
	const elemWriteMany = elementType._writeMany
	const elemReadMany = elementType._readMany
	const sideChannel = elementType._sideChannel ~= false

	local writeFn
	local readFn
	if elemWriteMany then
		writeFn = function(b, c, value, context)
			const len = #value
			if len < 128 then
				buf_writeu8(b, c, len)
				c += 1
			else
				c = writeLength(b, c, len)
			end
			return elemWriteMany(b, c, value, len, context)
		end

		readFn = function(b, c, context)
			local len = buf_readu8(b, c)
			if len < 128 then
				c += 1
			else
				len, c = readLengthSlow(b, c)
			end
			const out = table.create(len)
			return out, elemReadMany(b, c, out, len, context)
		end
	else
		writeFn = function(b, c, value, context)
			const len = #value
			if len < 128 then
				buf_writeu8(b, c, len)
				c += 1
			else
				c = writeLength(b, c, len)
			end
			for i = 1, len do
				c = elemWrite(b, c, value[i], context)
			end
			return c
		end

		readFn = function(b, c, context)
			local len = buf_readu8(b, c)
			if len < 128 then
				c += 1
			else
				len, c = readLengthSlow(b, c)
			end
			const out = table.create(len)
			for i = 1, len do
				out[i], c = elemRead(b, c, context)
			end
			return out, c
		end
	end

	if VALIDATE then
		const minBytes, minBits, minRefs = minWire(elementType)
		readFn = function(b, c, context)
			local len = buf_readu8(b, c)
			if len < 128 then
				c += 1
			else
				len, c = readLengthSlow(b, c)
			end
			checkCount(len, minBytes, minBits, minRefs, b, c, context, "array")
			const out = table.create(len)
			if elemReadMany then
				return out, elemReadMany(b, c, out, len, context)
			end
			for i = 1, len do
				out[i], c = elemRead(b, c, context)
			end
			return out, c
		end
	end

	const function checkFn(value)
		if type(value) ~= "table" then
			return false, "expected array, got " .. _typeof(value)
		end
		const len = #value
		for i = 1, len do
			const ok, err = elemCheck(value[i])
			if not ok then return false, "[" .. i .. "]: " .. err end
		end
		return true
	end

	if elemSize then
		return {
			_kind = "array",
			_elem = elementType,
			_sideChannel = sideChannel,
			sizeOf = function(value)
				const len = #value
				return lengthSize(len) + len * elemSize
			end,
			check = checkFn,
			write = writeFn,
			read = readFn,
		}
	else
		return {
			_kind = "array",
			_elem = elementType,
			_sideChannel = sideChannel,
			_costly = true,
			sizeOf = function(value)
				const len = #value
				local s = lengthSize(len)
				for i = 1, len do
					s += elemSizeOf(value[i])
				end
				return s
			end,
			check = checkFn,
			write = writeFn,
			read = readFn,
		}
	end
end

const function compileMap(keyType, valueType)
	const kWrite = keyType.write
	const kRead = keyType.read
	const kCheck = keyType.check
	const kSize = keyType.size
	const kSizeOf = keyType.sizeOf
	const vWrite = valueType.write
	const vRead = valueType.read
	const vCheck = valueType.check
	const vSize = valueType.size
	const vSizeOf = valueType.sizeOf

	const function writeFn(b, c, value, context)
		const lenCursor = c
		c += 2
		local count = 0
		for k, v in value do
			c = kWrite(b, c, k, context)
			c = vWrite(b, c, v, context)
			count += 1
		end
		if count > 16383 then
			error("bitnet: map has more than 16383 entries")
		end
		buf_writeu8(b, lenCursor, bit_bor(bit_band(count, 127), 128))
		buf_writeu8(b, lenCursor + 1, bit_rshift(count, 7))
		return c
	end

	const function readFn(b, c, context)
		local count = buf_readu8(b, c)
		if count < 128 then
			c += 1
		else
			count, c = readLengthSlow(b, c)
		end
		const out = {}
		for _ = 1, count do
			local k, v
			k, c = kRead(b, c, context)
			v, c = vRead(b, c, context)
			out[k] = v
		end
		return out, c
	end

	local mapRead = readFn
	if VALIDATE then
		const kb, kbits, krefs = minWire(keyType)
		const vb, vbits, vrefs = minWire(valueType)
		mapRead = function(b, c, context)
			local count = buf_readu8(b, c)
			if count < 128 then
				c += 1
			else
				count, c = readLengthSlow(b, c)
			end
			checkMapCount(count)
			checkCount(count, kb + vb, kbits + vbits, krefs + vrefs, b, c, context, "map")
			const out = {}
			for i = 1, count do
				local k, v
				k, c = kRead(b, c, context)
				if k == nil or k ~= k then
					fail(`map key #{i} is {tostring(k)}`)
				end
				v, c = vRead(b, c, context)
				out[k] = v
			end
			return out, c
		end
	end

	const function checkFn(value)
		if type(value) ~= "table" then
			return false, "expected table, got " .. _typeof(value)
		end
		for k, v in value do
			local ok, err = kCheck(k)
			if not ok then return false, "key: " .. err end
			ok, err = vCheck(v)
			if not ok then return false, "value at " .. tostring(k) .. ": " .. err end
		end
		return true
	end

	local sizeOfFn
	if kSize and vSize then
		const entrySize = kSize + vSize
		sizeOfFn = function(value)
			local count = 0
			for _ in value do
				count += 1
			end
			return 2 + count * entrySize
		end
	elseif kSize then
		sizeOfFn = function(value)
			local s = 2
			for _, v in value do
				s += kSize + vSizeOf(v)
			end
			return s
		end
	elseif vSize then
		sizeOfFn = function(value)
			local s = 2
			for k in value do
				s += kSizeOf(k) + vSize
			end
			return s
		end
	else
		sizeOfFn = function(value)
			local s = 2
			for k, v in value do
				s += kSizeOf(k) + vSizeOf(v)
			end
			return s
		end
	end

	return {
		_kind = "map",
		_key = keyType,
		_value = valueType,
		_sideChannel = keyType._sideChannel ~= false or valueType._sideChannel ~= false,
		_costly = true,
		sizeOf = sizeOfFn,
		check = checkFn,
		write = writeFn,
		read = mapRead,
	}
end

const function compileOptional(innerType)
	const innerWrite = innerType.write
	const innerRead = innerType.read
	const innerCheck = innerType.check
	const innerSize = innerType.size
	const innerSizeOf = innerType.sizeOf

	const compiled = {
		_kind = "optional",
		_inner = innerType,
		_sideChannel = true,
		_minBytes = 0,
		_minBits = 1,
		_costly = innerType._costly,
		sizeOf = function(value)
			if value == nil then return 0 end
			return innerSize or innerSizeOf(value)
		end,
		check = function(value)
			if value == nil then return true end
			return innerCheck(value)
		end,
		write = function(b, c, value, context)
			const present = value ~= nil
			const bits = context.value * 2 + if present then 1 else 0
			if bits >= 256 then
				const amount = context.amount + 1
				context.bools[amount] = bits - 256
				context.amount = amount
				context.value = 1
			else
				context.value = bits
			end
			if present then
				return innerWrite(b, c, value, context)
			end
			return c
		end,
		read = function(b, c, context)
			local bits = context.value
			if bits == 256 then
				bits = buf_readu8(context.bools, context.amount) * 2 + 1
				context.amount += 1
			end
			const present = bits >= 256
			context.value = bits % 256 * 2
			if present then
				return innerRead(b, c, context)
			end
			return nil, c
		end,
	}
	if VALIDATE then
		compiled.read = function(b, c, context)
			if strictBool(b, c, context) then
				return innerRead(b, c, context)
			end
			return nil, c
		end
	end
	return compiled
end

const instanceCache: { [string]: any } = {}

const function compileInstance(...: string)
	const classNames = { ... }
	const n = #classNames
	for i = 1, n do
		if type(classNames[i]) ~= "string" then
			error(`bitnet: types.instance class name {i} must be a string, got {_typeof(classNames[i])}`, 2)
		end
	end
	const key = table.concat(classNames, "\0")
	const cached = instanceCache[key]
	if cached then
		return cached
	end

	const expected = if n == 0 then "instance" else table.concat(classNames, " or ")
	const function allowed(v: Instance): boolean
		for i = 1, n do
			if v:IsA(classNames[i]) then
				return true
			end
		end
		return n == 0
	end

	const compiled = {
		size = 0,
		_minRefs = 1,
		_sideChannel = true,
		check = function(v)
			if v == nil then return true end
			if _typeof(v) ~= "Instance" then
				return false, `{expected} expected, got {_typeof(v)}`
			end
			if not allowed(v) then
				return false, `{expected} expected, got {v.ClassName}`
			end
			return true
		end,
		write = function(b, c, v, context)
			const count = context.refCount + 1
			context.refCount = count
			context.refs[count] = if v == nil then false else v
			return c
		end,
		read = function(b, c, context)
			const count = context.refCount + 1
			context.refCount = count
			const v = context.refs[count]
			return (if v then v else nil), c
		end,
	}
	if VALIDATE then
		compiled.read = function(b, c, context)
			const count = context.refCount + 1
			context.refCount = count
			const v = context.refs[count]
			if not v then
				return nil, c
			end
			if _typeof(v) ~= "Instance" then
				fail(`{expected} expected, got {_typeof(v)}`)
			end
			if n > 0 and not allowed(v) then
				fail(`{expected} expected, got {v.ClassName}`)
			end
			return v, c
		end
	end
	instanceCache[key] = compiled
	return compiled
end

const function compileCompress(innerType, level: number?)
	if EncodingService == nil then
		error("bitnet: types.compress requires EncodingService, which is unavailable here", 2)
	end
	if innerType == nil or innerType.write == nil or innerType.read == nil then
		error("bitnet: types.compress expects a compiled bitnet type", 2)
	end

	const algorithm = CompressionAlgorithm
	const service = EncodingService
	const lvl = if level == nil then COMPRESS_DEFAULT_LEVEL else level
	const innerWrite = innerType.write
	const innerRead = innerType.read
	const innerSize = innerType.size
	const innerSizeOf = innerType.sizeOf

	const compiled = {
		_costly = true,
		_sideChannel = innerType._sideChannel ~= false,
		_isTuple = innerType._isTuple,
		_arity = innerType._arity,
		check = innerType.check,
		sizeOf = function(value)
			const raw = innerSize or innerSizeOf(value)
			return lengthSize(raw * 2 + 1) + raw
		end,
		write = function(b, c, value, context)
			const raw = innerSize or innerSizeOf(value)
			const scratch = buf_create(raw + 1)
			const written = innerWrite(scratch, 0, value, context)

			local payload = nil
			local len = written
			local compressed = 0
			if written >= COMPRESS_MIN_BYTES then
				const exact = buf_create(written)
				buf_copy(exact, 0, scratch, 0, written)
				const packed = service:CompressBuffer(exact, algorithm, lvl)
				if buf_len(packed) < written then
					payload = packed
					len = buf_len(packed)
					compressed = 1
				end
			end

			const header = len * 2 + compressed
			if header < 128 then
				buf_writeu8(b, c, header)
				c += 1
			else
				c = writeLength(b, c, header)
			end
			const source = if payload then payload else scratch
			buf_copy(b, c, source, 0, len)
			return c + len
		end,
		read = function(b, c, context)
			local header = buf_readu8(b, c)
			if header < 128 then
				c += 1
			else
				header, c = readLengthSlow(b, c)
			end
			const compressed = header % 2
			const len = (header - compressed) / 2

			if compressed == 0 then
				const value = innerRead(b, c, context)
				return value, c + len
			end

			const packed = buf_create(len)
			buf_copy(packed, 0, b, c, len)
			const value = innerRead(service:DecompressBuffer(packed, algorithm), 0, context)
			return value, c + len
		end,
	}
	if VALIDATE then
		compiled.read = function(b, c, context)
			local header = buf_readu8(b, c)
			if header < 128 then
				c += 1
			else
				header, c = readLengthSlow(b, c)
			end
			const compressed = header % 2
			const len = (header - compressed) / 2
			const left = buf_len(b) - c
			if len > left then
				fail(`compress payload of {len} bytes, {left} left`)
			end

			if compressed == 0 then
				const value, innerEnd = innerRead(b, c, context)
				if innerEnd ~= c + len then
					fail(`compress payload declared {len} bytes but its value took {innerEnd - c}`)
				end
				return value, c + len
			end

			const size = zstdContentSize(b, c, c + len)
			const spent = context.inflated or 0
			if spent + size > MAX_DECOMPRESSED then
				fail(`compress payload would inflate to {size} bytes, {MAX_DECOMPRESSED - spent} left for this batch`)
			end
			context.inflated = spent + size
			const packed = buf_create(len)
			buf_copy(packed, 0, b, c, len)
			const raw = service:DecompressBuffer(packed, algorithm)
			const value, innerEnd = innerRead(raw, 0, context)
			if innerEnd ~= buf_len(raw) then
				fail(`compress payload inflated to {buf_len(raw)} bytes but its value took {innerEnd}`)
			end
			return value, c + len
		end
	end
	return compiled
end

const enumTypes: { [Enum]: any } = {}
const enumItemValue: { [EnumItem]: number } = {}
const enumItemOwner: { [EnumItem]: Enum } = {}

const function compileEnum(enumType: Enum)
	if _typeof(enumType) ~= "Enum" then
		error(`bitnet: types.enum expects an Enum, got {_typeof(enumType)}`, 2)
	end

	const cached = enumTypes[enumType]
	if cached then
		return cached
	end

	const name = "Enum." .. tostring(enumType)
	const itemByValue: { [number]: EnumItem } = {}
	local maxValue = 0
	for _, item in enumType:GetEnumItems() do
		const value = item.Value
		enumItemValue[item] = value
		enumItemOwner[item] = enumType
		if itemByValue[value] == nil then
			itemByValue[value] = enumType:FromValue(value)
		end
		if value > maxValue then
			maxValue = value
		end
	end

	local width, writeValue, readValue
	if maxValue <= 255 then
		width, writeValue, readValue = 1, buf_writeu8, buf_readu8
	elseif maxValue <= 65535 then
		width, writeValue, readValue = 2, buf_writeu16, buf_readu16
	else
		width, writeValue, readValue = 4, buf_writeu32, buf_readu32
	end

	const compiled = {
		size = width,
		_sideChannel = false,
		check = function(v)
			if enumItemOwner[v] == enumType then
				return true
			end
			if _typeof(v) ~= "EnumItem" then
				return false, "expected " .. name .. ", got " .. _typeof(v)
			end
			if v.EnumType ~= enumType then
				return false, "expected " .. name .. ", got " .. tostring(v)
			end
			return true
		end,
		write = function(b, c, v)
			local value = enumItemValue[v] or v.Value
			writeValue(b, c, value)
			return c + width
		end,
		read = function(b, c)
			const value = readValue(b, c)
			local item = itemByValue[value]
			if item == nil then
				item = enumType:FromValue(value)
				if item == nil then
					error(`bitnet: {name} has no item with value {value}`)
				end
				itemByValue[value] = item
			end
			return item, c + width
		end,
	}
	enumTypes[enumType] = compiled
	return compiled
end

const enumFromKeysCache = setmetatable({}, { __mode = "k" })
const enumFromValuesCache = setmetatable({}, { __mode = "k" })

const function compileSymbols(symbols: { string }, origin: string)
	const n = #symbols
	if n == 0 then
		error(`bitnet: types.{origin} needs at least one symbol`, 3)
	end
	table.sort(symbols)

	const indexOf: { [string]: number } = {}
	for i = 1, n do
		const s = symbols[i]
		if indexOf[s] ~= nil then
			error(`bitnet: types.{origin} has duplicate symbol "{s}"`, 3)
		end
		indexOf[s] = i - 1
	end

	local width, writeValue, readValue
	if n <= 256 then
		width, writeValue, readValue = 1, buf_writeu8, buf_readu8
	elseif n <= 65536 then
		width, writeValue, readValue = 2, buf_writeu16, buf_readu16
	else
		width, writeValue, readValue = 4, buf_writeu32, buf_readu32
	end

	const preview = table.concat(symbols, ", ", 1, math.min(3, n))
	const name = if n > 3 then `enum<{preview}, ... {n} symbols>` else `enum<{preview}>`

	return {
		size = width,
		_sideChannel = false,
		_fingerprint = hash(table.concat(symbols, "\0")),
		check = function(v)
			if indexOf[v] ~= nil then
				return true
			end
			if type(v) ~= "string" then
				return false, `expected a {name} symbol, got {_typeof(v)}`
			end
			return false, `"{v}" is not a member of {name}`
		end,
		write = function(b, c, v)
			const index = indexOf[v]
			if index == nil then
				error(`bitnet: "{tostring(v)}" is not a member of {name}`)
			end
			writeValue(b, c, index)
			return c + width
		end,
		read = function(b, c)
			const index = readValue(b, c)
			const s = symbols[index + 1]
			if s == nil then
				error(`bitnet: {name} has no symbol at index {index}`)
			end
			return s, c + width
		end,
		_writeMany = function(b, c, value, len)
			for i = 1, len do
				const index = indexOf[value[i]]
				if index == nil then
					error(`bitnet: "{tostring(value[i])}" is not a member of {name}`)
				end
				writeValue(b, c, index)
				c += width
			end
			return c
		end,
		_readMany = function(b, c, out, len)
			for i = 1, len do
				const index = readValue(b, c)
				const s = symbols[index + 1]
				if s == nil then
					error(`bitnet: {name} has no symbol at index {index}`)
				end
				out[i] = s
				c += width
			end
			return c
		end,
	}
end

const function compileEnumFromKeys(source: { [string]: any })
	if type(source) ~= "table" then
		error(`bitnet: types.enumFromKeys expects a table, got {_typeof(source)}`, 2)
	end
	const cached = enumFromKeysCache[source]
	if cached then
		return cached
	end

	const symbols = {}
	local n = 0
	for key in source do
		if type(key) ~= "string" then
			error(`bitnet: types.enumFromKeys needs string keys, got {_typeof(key)}`, 2)
		end
		n += 1
		symbols[n] = key
	end

	const compiled = compileSymbols(symbols, "enumFromKeys")
	enumFromKeysCache[source] = compiled
	return compiled
end

const function compileEnumFromValues(source: { [any]: string })
	if type(source) ~= "table" then
		error(`bitnet: types.enumFromValues expects a table, got {_typeof(source)}`, 2)
	end
	const cached = enumFromValuesCache[source]
	if cached then
		return cached
	end

	const symbols = {}
	local n = 0
	for _, value in source do
		if type(value) ~= "string" then
			error(`bitnet: types.enumFromValues needs string values, got {_typeof(value)}`, 2)
		end
		n += 1
		symbols[n] = value
	end

	const compiled = compileSymbols(symbols, "enumFromValues")
	enumFromValuesCache[source] = compiled
	return compiled
end

const function compileTuple(...)
	const elements = {...}
	const n = #elements
	if n == 0 then return primitives.nothing end
	if n == 1 then return elements[1] end
	for i = 1, n do
		const t = elements[i]
		assert(t and t.write and t.read,
			`bitnet: types.tuple element {i} is not compiled type`)
	end

	const writers = table.create(n)
	const readers = table.create(n)
	const fieldTypes = table.create(n)
	const fieldChecks = table.create(n)
	local totalSize = 0
	local allFixed = true
	local costly = false
	local sideChannel = false
	local minBytes, minBits, minRefs = 0, 0, 0

	for i = 1, n do
		const t = elements[i]
		writers[i] = t.write
		readers[i] = t.read
		fieldTypes[i] = t
		fieldChecks[i] = t.check
		if t._costly then
			costly = true
		end
		if t.size then
			totalSize += t.size
		else
			allFixed = false
		end
		if t._sideChannel ~= false then
			sideChannel = true
		end
		const tb, tbits, trefs = minWire(t)
		minBytes += tb
		minBits += tbits
		minRefs += trefs
	end

	const function writeFn(b, c, value, context)
		for i = 1, n do
			c = writers[i](b, c, value[i], context)
		end
		return c
	end

	const function readFn(b, c, context)
		const out = table.create(n)
		for i = 1, n do
			out[i], c = readers[i](b, c, context)
		end
		return out, c
	end

	const function checkFn(value)
		if type(value) ~= "table" then
			return false, "expected table for tuple, got " .. _typeof(value)
		end
		for i = 1, n do
			const ok, err = fieldChecks[i](value[i])
			if not ok then return false, "tuple[" .. i .. "]: " .. err end
		end
		return true
	end

	local writeArgs, readArgs, sizeArgs
	if n <= MAX_SPREAD_ARITY then
		const function element(index: number, key: string)
			const t = elements[index]
			return if t then t[key] else nil
		end
		const w1, w2, w3, w4, w5, w6 = writers[1], writers[2], writers[3], writers[4], writers[5], writers[6]
		const r1, r2, r3, r4, r5, r6 = readers[1], readers[2], readers[3], readers[4], readers[5], readers[6]

		writeArgs = function(b, c, v1, context, v2, v3, v4, v5, v6)
			c = w1(b, c, v1, context)
			c = w2(b, c, v2, context)
			if n == 2 then return c end
			c = w3(b, c, v3, context)
			if n == 3 then return c end
			c = w4(b, c, v4, context)
			if n == 4 then return c end
			c = w5(b, c, v5, context)
			if n == 5 then return c end
			return w6(b, c, v6, context)
		end

		readArgs = function(b, c, context)
			local v1, v2, v3, v4, v5, v6
			v1, c = r1(b, c, context)
			v2, c = r2(b, c, context)
			if n == 2 then
				context.readCursor = c
				return v1, v2
			end
			v3, c = r3(b, c, context)
			if n == 3 then
				context.readCursor = c
				return v1, v2, v3
			end
			v4, c = r4(b, c, context)
			if n == 4 then
				context.readCursor = c
				return v1, v2, v3, v4
			end
			v5, c = r5(b, c, context)
			if n == 5 then
				context.readCursor = c
				return v1, v2, v3, v4, v5
			end
			v6, c = r6(b, c, context)
			context.readCursor = c
			return v1, v2, v3, v4, v5, v6
		end

		if not allFixed then
			const s1, s2, s3 = element(1, "size"), element(2, "size"), element(3, "size")
			const s4, s5, s6 = element(4, "size"), element(5, "size"), element(6, "size")
			const f1, f2, f3 = element(1, "sizeOf"), element(2, "sizeOf"), element(3, "sizeOf")
			const f4, f5, f6 = element(4, "sizeOf"), element(5, "sizeOf"), element(6, "sizeOf")
			sizeArgs = function(v1, v2, v3, v4, v5, v6)
				local s = (s1 or f1(v1)) + (s2 or f2(v2))
				if n == 2 then return s end
				s += s3 or f3(v3)
				if n == 3 then return s end
				s += s4 or f4(v4)
				if n == 4 then return s end
				s += s5 or f5(v5)
				if n == 5 then return s end
				return s + (s6 or f6(v6))
			end
		end
	end

	local compiled
	if allFixed then
		compiled = {
			_isTuple = true,
			_arity = n,
			_writeArgs = writeArgs,
			_readArgs = readArgs,
			size = totalSize,
			check = checkFn,
			write = writeFn,
			read = readFn,
		}
	else
		compiled = {
			_isTuple = true,
			_arity = n,
			_costly = costly,
			_writeArgs = writeArgs,
			_readArgs = readArgs,
			_sizeArgs = sizeArgs,
			sizeOf = function(value)
				local s = 0
				for i = 1, n do
					const t = fieldTypes[i]
					s += t.size or t.sizeOf(value[i])
				end
				return s
			end,
			check = checkFn,
			write = writeFn,
			read = readFn,
		}
	end
	compiled._kind = "tuple"
	compiled._sideChannel = sideChannel
	compiled._types = fieldTypes
	compiled._minBytes = minBytes
	compiled._minBits = minBits
	compiled._minRefs = minRefs
	return compiled
end

const fixedVec3Cache: { [number]: any } = {}
const fixedVec2Cache: { [number]: any } = {}

const function compileVec3i16(scale: number?)
	const s = if scale == nil then 100 else scale
	const cached = fixedVec3Cache[s]
	if cached then
		return cached
	end

	const inv = 1 / s
	const limit = 32767 / s
	const compiled = {
		size = 6,
		_sideChannel = false,
		check = function(v)
			if _typeof(v) ~= "Vector3" then
				return false, "expected Vector3, got " .. _typeof(v)
			end
			if v.X > limit or v.X < -limit
				or v.Y > limit or v.Y < -limit
				or v.Z > limit or v.Z < -limit then
				return false, `vec3i16 out of range [-{limit}, {limit}]: {tostring(v)}`
			end
			return true
		end,
		write = function(b, c, v)
			buf_writei16(b, c,     _floor(v.X * s + 0.5))
			buf_writei16(b, c + 2, _floor(v.Y * s + 0.5))
			buf_writei16(b, c + 4, _floor(v.Z * s + 0.5))
			return c + 6
		end,
		read = function(b, c)
			return Vector3.new(
				buf_readi16(b, c) * inv,
				buf_readi16(b, c + 2) * inv,
				buf_readi16(b, c + 4) * inv
			), c + 6
		end,
		_writeMany = function(b, c, value, len)
			for i = 1, len do
				const v = value[i]
				buf_writei16(b, c,     _floor(v.X * s + 0.5))
				buf_writei16(b, c + 2, _floor(v.Y * s + 0.5))
				buf_writei16(b, c + 4, _floor(v.Z * s + 0.5))
				c += 6
			end
			return c
		end,
		_readMany = function(b, c, out, len)
			for i = 1, len do
				out[i] = Vector3.new(
					buf_readi16(b, c) * inv,
					buf_readi16(b, c + 2) * inv,
					buf_readi16(b, c + 4) * inv
				)
				c += 6
			end
			return c
		end,
	}
	fixedVec3Cache[s] = compiled
	return compiled
end

const function compileVec2i16(scale: number?)
	const s = if scale == nil then 100 else scale
	const cached = fixedVec2Cache[s]
	if cached then
		return cached
	end

	const inv = 1 / s
	const limit = 32767 / s
	const compiled = {
		size = 4,
		_sideChannel = false,
		check = function(v)
			if _typeof(v) ~= "Vector2" then
				return false, "expected Vector2, got " .. _typeof(v)
			end
			if v.X > limit or v.X < -limit or v.Y > limit or v.Y < -limit then
				return false, `vec2i16 out of range [-{limit}, {limit}]: {tostring(v)}`
			end
			return true
		end,
		write = function(b, c, v)
			buf_writei16(b, c,     _floor(v.X * s + 0.5))
			buf_writei16(b, c + 2, _floor(v.Y * s + 0.5))
			return c + 4
		end,
		read = function(b, c)
			return Vector2.new(
				buf_readi16(b, c) * inv,
				buf_readi16(b, c + 2) * inv
			), c + 4
		end,
		_writeMany = function(b, c, value, len)
			for i = 1, len do
				const v = value[i]
				buf_writei16(b, c,     _floor(v.X * s + 0.5))
				buf_writei16(b, c + 2, _floor(v.Y * s + 0.5))
				c += 4
			end
			return c
		end,
		_readMany = function(b, c, out, len)
			for i = 1, len do
				out[i] = Vector2.new(buf_readi16(b, c) * inv, buf_readi16(b, c + 2) * inv)
				c += 4
			end
			return c
		end,
	}
	fixedVec2Cache[s] = compiled
	return compiled
end

const types = {}
for k, v in primitives do
	types[k] = v
end
types.struct = compileStruct
types.array = compileArray
types.map = compileMap
types.optional = compileOptional
types.instance = compileInstance
types.enum = compileEnum
types.enumFromKeys = compileEnumFromKeys
types.enumFromValues = compileEnumFromValues
types.tuple = compileTuple
types.vec3i16 = compileVec3i16
types.vec2i16 = compileVec2i16
types.compress = compileCompress

-- .auto support

const TAG_NIL = 0
const TAG_BOOL = 1
const TAG_NUMBER = 2
const TAG_STRING = 3
const TAG_VEC2 = 4
const TAG_VEC3 = 5
const TAG_COLOR3 = 6
const TAG_CFRAME = 7
const TAG_BUFFER = 8
const TAG_REF = 9
const TAG_ARRAY = 10
const TAG_MAP = 11
const TAG_TUPLE = 12
const TAG_BRICKCOLOR = 13
const TAG_NUMBERRANGE = 14
const TAG_UDIM = 15
const TAG_UDIM2 = 16
const TAG_NUMBERSEQUENCE = 17
const TAG_COLORSEQUENCE = 18

const TAG_TO_TYPE = {
	[TAG_NIL] = primitives.nothing,
	[TAG_BOOL] = primitives.bool,
	[TAG_NUMBER] = primitives.f64,
	[TAG_STRING] = primitives.string,
	[TAG_VEC2] = primitives.vec2,
	[TAG_VEC3] = primitives.vec3,
	[TAG_COLOR3] = primitives.color3,
	[TAG_CFRAME] = primitives.cframe,
	[TAG_BUFFER] = primitives.buffer,
	[TAG_REF] = primitives.ref,
	[TAG_BRICKCOLOR] = primitives.brickcolor,
	[TAG_NUMBERRANGE] = primitives.numberrange,
	[TAG_UDIM] = primitives.udim,
	[TAG_UDIM2] = primitives.udim2,
	[TAG_NUMBERSEQUENCE] = primitives.numbersequence,
	[TAG_COLORSEQUENCE] = primitives.colorsequence,
}

const function classifyTable(t): number
	const packed = rawget(t, "n")
	if packed ~= nil then
		if type(packed) ~= "number" or packed < 0 or packed % 1 ~= 0 then
			return TAG_MAP
		end
		local count = 0
		for k in t do
			if k ~= "n" then
				if type(k) ~= "number" or k < 1 or k > packed or k % 1 ~= 0 then
					return TAG_MAP
				end
				count += 1
			end
		end
		return if packed - count <= count + 8 then TAG_TUPLE else TAG_MAP
	end
	const n = #t
	if n == 0 then
		return if next(t) == nil then TAG_ARRAY else TAG_MAP
	end
	local count = 0
	for _ in t do
		count += 1
	end
	return if count == n then TAG_ARRAY else TAG_MAP
end

const function tagFor(v)
	if v == nil then return TAG_NIL end
	const t = _typeof(v)
	if t == "boolean" then return TAG_BOOL end
	if t == "number" then return TAG_NUMBER end
	if t == "string" then return TAG_STRING end
	if t == "Vector2" then return TAG_VEC2 end
	if t == "Vector3" then return TAG_VEC3 end
	if t == "Color3" then return TAG_COLOR3 end
	if t == "CFrame" then return TAG_CFRAME end
	if t == "buffer" then return TAG_BUFFER end
	if t == "table" then return classifyTable(v) end
	if t == "BrickColor" then return TAG_BRICKCOLOR end
	if t == "NumberRange" then return TAG_NUMBERRANGE end
	if t == "UDim" then return TAG_UDIM end
	if t == "UDim2" then return TAG_UDIM2 end
	if t == "NumberSequence" then return TAG_NUMBERSEQUENCE end
	if t == "ColorSequence" then return TAG_COLORSEQUENCE end
	return TAG_REF
end

local sizeOfAuto
local writeAuto
local readAuto

function sizeOfAuto(v)
	const tag = tagFor(v)
	if tag == TAG_ARRAY or tag == TAG_TUPLE then
		const n = if tag == TAG_TUPLE then rawget(v, "n") else #v
		local s = 1 + lengthSize(n)
		for i = 1, n do s += sizeOfAuto(v[i]) end
		return s
	elseif tag == TAG_MAP then
		local s = 3
		for k, val in v do
			s += sizeOfAuto(k) + sizeOfAuto(val)
		end
		return s
	end
	const t = TAG_TO_TYPE[tag]
	return 1 + (t.size or t.sizeOf(v))
end

function writeAuto(b, c, v, context)
	const tag = tagFor(v)
	buf_writeu8(b, c, tag)
	c += 1
	if tag == TAG_ARRAY or tag == TAG_TUPLE then
		const n = if tag == TAG_TUPLE then rawget(v, "n") else #v
		if n < 128 then
			buf_writeu8(b, c, n)
			c += 1
		else
			c = writeLength(b, c, n)
		end
		for i = 1, n do c = writeAuto(b, c, v[i], context) end
		return c
	elseif tag == TAG_MAP then
		const countCursor = c
		c += 2
		local count = 0
		for k, val in v do
			c = writeAuto(b, c, k, context)
			c = writeAuto(b, c, val, context)
			count += 1
		end
		if count > 16383 then
			error("bitnet: types.auto map has more than 16383 entries")
		end
		buf_writeu8(b, countCursor, bit_bor(bit_band(count, 127), 128))
		buf_writeu8(b, countCursor + 1, bit_rshift(count, 7))
		return c
	end
	return TAG_TO_TYPE[tag].write(b, c, v, context)
end

function readAuto(b, c, context)
	const tag = buf_readu8(b, c)
	c += 1
	if tag == TAG_ARRAY then
		local n = buf_readu8(b, c)
		if n < 128 then
			c += 1
		else
			n, c = readLengthSlow(b, c)
		end
		const out = table.create(n)
		for i = 1, n do out[i], c = readAuto(b, c, context) end
		return out, c
	elseif tag == TAG_TUPLE then
		local n = buf_readu8(b, c)
		if n < 128 then
			c += 1
		else
			n, c = readLengthSlow(b, c)
		end
		const out = table.create(n)
		for i = 1, n do out[i], c = readAuto(b, c, context) end
		out.n = n
		return out, c
	elseif tag == TAG_MAP then
		local count = buf_readu8(b, c)
		if count < 128 then
			c += 1
		else
			count, c = readLengthSlow(b, c)
		end
		const out = {}
		for _ = 1, count do
			local k
			k, c = readAuto(b, c, context)
			local val
			val, c = readAuto(b, c, context)
			out[k] = val
		end
		return out, c
	end
	const t = TAG_TO_TYPE[tag]
	if not t then error("bitnet: types.auto unknown tag " .. tag) end
	return t.read(b, c, context)
end

local readAutoStrict

function readAutoStrict(b, c, context, depth)
	const tag = buf_readu8(b, c)
	c += 1
	if tag == TAG_ARRAY or tag == TAG_TUPLE or tag == TAG_MAP then
		const level = (depth or 0) + 1
		if level > AUTO_MAX_DEPTH then
			fail(`auto nests deeper than {AUTO_MAX_DEPTH} levels`)
		end
		local n = buf_readu8(b, c)
		if n < 128 then
			c += 1
		else
			n, c = readLengthSlow(b, c)
		end
		if tag == TAG_MAP then
			checkCount(n, 2, 0, 0, b, c, context, "auto map")
			const out = {}
			for i = 1, n do
				local k, val
				k, c = readAutoStrict(b, c, context, level)
				if k == nil or k ~= k then
					fail(`auto map key #{i} is {tostring(k)}`)
				end
				val, c = readAutoStrict(b, c, context, level)
				out[k] = val
			end
			return out, c
		end
		checkCount(n, 1, 0, 0, b, c, context, "auto array")
		const out = table.create(n)
		for i = 1, n do
			out[i], c = readAutoStrict(b, c, context, level)
		end
		if tag == TAG_TUPLE then
			out.n = n
		end
		return out, c
	end
	const t = TAG_TO_TYPE[tag]
	if not t then
		fail(`auto has unknown tag {tag}`)
	end
	return t.read(b, c, context)
end

const function checkAuto(v)
	const lt = type(v)
	if lt == "function" or lt == "thread" then
		return false, "types.auto cannot encode " .. lt
	end
	if lt == "table" then
		const tag = classifyTable(v)
		if tag == TAG_ARRAY or tag == TAG_TUPLE then
			const n = if tag == TAG_TUPLE then rawget(v, "n") else #v
			for i = 1, n do
				const ok, err = checkAuto(v[i])
				if not ok then return false, "[" .. i .. "]: " .. err end
			end
		else
			for k, val in v do
				local ok, err = checkAuto(k)
				if not ok then return false, "key: " .. err end
				ok, err = checkAuto(val)
				if not ok then return false, "value at " .. tostring(k) .. ": " .. err end
			end
		end
	end
	return true
end

types.auto = {
	_costly = true,
	_sideChannel = true,
	sizeOf = sizeOfAuto,
	check = checkAuto,
	write = writeAuto,
	read = if VALIDATE then readAutoStrict else readAuto,
}

return {
	types = types,
	primitives = primitives,
	locate = locate,
	cleanError = cleanError,
}
