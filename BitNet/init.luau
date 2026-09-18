--!native
--!optimize 2

-- VERSION 3.0

const IS_STUDIO = game:GetService("RunService"):IsStudio()

if IS_STUDIO then
	const readme = require(script.readme) -- AIs need to read it
end

const codec = require(script.codec)
const event = require(script.instances.event)
const func = require(script.instances.func)
const signal = require(script.instances.signal)
const dispatch = require(script.runtime.dispatch)

const types = require(script.types)

if IS_STUDIO then
	print('Bitnet: initialized')
end

return {
	types = codec.types,

	event = event.new,
	func = func.new,
	signal = signal.new,
} :: types.Bitnet