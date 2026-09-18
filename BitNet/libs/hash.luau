--!native
--!optimize 2

-- FNV-1a 32-bit hash returns an unsigned 32-bit integer
const function hash(str: string): number
	local h = 2166136261
	for i = 1, #str do
		h = bit32.bxor(h, string.byte(str, i))
		h = (h * 16777619) % 4294967296
	end
	return h
end

return hash