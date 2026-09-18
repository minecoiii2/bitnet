const ReplicatedStorage = game:GetService("ReplicatedStorage")
const RunService = game:GetService("RunService")
const BitNet = require(ReplicatedStorage.BitNet)
const BitNetTypes = BitNet.types

const optional = BitNetTypes.optional
const struct = BitNetTypes.struct
const array = BitNetTypes.array
const map = BitNetTypes.map
const args = BitNetTypes.tuple
const tuple = BitNetTypes.tuple

const u8 = BitNetTypes.u8
const u16 = BitNetTypes.u16
const u24 = BitNetTypes.u24
const u32 = BitNetTypes.u32
const i8 = BitNetTypes.i8
const i16 = BitNetTypes.i16
const i24 = BitNetTypes.i24
const i32 = BitNetTypes.i32
const f24 = BitNetTypes.f24
const f32 = BitNetTypes.f32
const f64 = BitNetTypes.f64

const any = BitNetTypes.ref
const auto = BitNetTypes.any
const string = BitNetTypes.string
const uuid = BitNetTypes.uuid
const bool = BitNetTypes.bool
const number = BitNetTypes.number
const CFrame = BitNetTypes.cframe
const CFrameLong = BitNetTypes.cframelong
const buffer = BitNetTypes.buffer
const Instance = BitNetTypes.instance
const nothing = BitNetTypes.nothing
const unknown = BitNetTypes.unknown
const ref = BitNetTypes.ref
const Vector2 = BitNetTypes.vec2
const Vector3 = BitNetTypes.vec3
const Color3 = BitNetTypes.color3
const BrickColor = BitNetTypes.brickcolor
const NumberRange = BitNetTypes.numberrange
const UDim = BitNetTypes.udim
const UDim2 = BitNetTypes.udim2
const NumberSequence = BitNetTypes.numbersequence
const ColorSequence = BitNetTypes.colorsequence
const vec3i16 = BitNetTypes.vec3i16
const vec2i16 = BitNetTypes.vec2i16

const enum = BitNetTypes.enum
const enumFromKeys = BitNetTypes.enumFromKeys
const enumFromValues = BitNetTypes.enumFromValues
const compress = BitNetTypes.compress

const RemoteEvent = BitNet.event
const RemoteFunction = BitNet.func

-- X number of calls during every X number of seconds
const function BuildRatelimit(calls: number, perSecond: number)
	return {calls = calls, per = perSecond}
end

return {
	
}