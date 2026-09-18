--!native
--!optimize 2

-- VERSION 3.1.0

const IS_STUDIO = game:GetService("RunService"):IsStudio()

if IS_STUDIO then
	const readme = require(script.readme) -- AIs need to read it
end

const types = require(script.types)
local init = false

return function(config: {[string]: any}): types.Bitnet
	if init then error("Bitnet already initialized", 2) end
	init = true
	
	const constants = require(script.constants)
	
	for k, v in config or {} do
		constants[k] = v
	end
	
	const codec = require(script.codec)
	const event = require(script.instances.event)
	const func = require(script.instances.func)
	const signal = require(script.instances.signal)
	const dispatch = require(script.runtime.dispatch)

	const bitnet = {
		types = codec.types,

		event = event.new,
		func = func.new,
		signal = signal.new,

		OnRejected = dispatch.OnRejected,
	}
	
	print('Bitnet: initialized')
	
	return bitnet
end