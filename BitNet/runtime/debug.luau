-- Debug output for events and funcs. Nothing here runs unless DEBUG or an endpoint's Debug is on: an
-- endpoint wraps its send and receive paths at creation only in that case, so with both off there is
-- nothing in those paths to pay for.

const RunService = game:GetService("RunService")
const IS_SERVER = RunService:IsServer()

const constants = require(script.Parent.Parent.constants)
const Signal = require(script.Parent.Parent.instances.signal)

const ENABLED = constants.DEBUG == true
const MAX_ENTRIES = 8
const MAX_DEPTH = 2
const MAX_STRING = 60

const module = {
	enabled = ENABLED,
	EventSent = if ENABLED then Signal.new() else nil,
	EventReceived = if ENABLED then Signal.new() else nil,
}

local function describe(value, depth: number): string
	const kind = typeof(value)
	if kind == "string" then
		if #value > MAX_STRING then
			return string.format("%q..", string.sub(value, 1, MAX_STRING))
		end
		return string.format("%q", value)
	elseif kind == "nil" or kind == "boolean" or kind == "number" then
		return tostring(value)
	elseif kind == "Instance" then
		return value:GetFullName()
	elseif kind == "buffer" then
		return `buffer({buffer.len(value)})`
	elseif kind ~= "table" then
		return `{kind}({tostring(value)})`
	elseif depth >= MAX_DEPTH then
		return "{..}"
	end
	const parts = {}
	const length = #value
	for key, inner in value do
		if #parts == MAX_ENTRIES then
			table.insert(parts, "..")
			break
		end
		if type(key) == "number" and key >= 1 and key <= length and key % 1 == 0 then
			table.insert(parts, describe(inner, depth + 1))
		elseif type(key) == "string" then
			table.insert(parts, `{key} = {describe(inner, depth + 1)}`)
		else
			table.insert(parts, `[{describe(key, depth + 1)}] = {describe(inner, depth + 1)}`)
		end
	end
	return "{" .. table.concat(parts, ", ") .. "}"
end

const function describeAll(...): string
	const count = select("#", ...)
	const parts = table.create(count)
	for i = 1, count do
		parts[i] = describe((select(i, ...)), 0)
	end
	return table.concat(parts, ", ")
end

-- nil is every client when the server sends and the server otherwise; a list is a streamed fire's recipients
const function describePeer(peer, sending: boolean): string
	if peer == nil then
		return if IS_SERVER and sending then "all clients" else "server"
	elseif type(peer) == "table" and (#peer > 0 or next(peer) == nil) then
		const names = {}
		for i, player in peer do
			if i > 4 then
				table.insert(names, "..")
				break
			end
			table.insert(names, player.Name)
		end
		return `{#peer} nearby ({table.concat(names, ", ")})`
	end
	return peer.Name
end

function module.sent(endpoint, printing: boolean, action: string, target, ...)
	if printing then
		print(`[BitNet] {endpoint.kind} #{endpoint.id} {action} -> {describePeer(target, true)}: {describeAll(...)}`)
	end
	const signal = module.EventSent
	if signal then
		signal:Fire(endpoint, action, target, ...)
	end
end

function module.received(endpoint, printing: boolean, action: string, source, ...)
	if printing then
		print(`[BitNet] {endpoint.kind} #{endpoint.id} {action} <- {describePeer(source, false)}: {describeAll(...)}`)
	end
	const signal = module.EventReceived
	if signal then
		signal:Fire(endpoint, action, source, ...)
	end
end

-- a received event reaches its handlers through the endpoint's own signal, so that is where it's seen;
-- the override lives on that one signal instance, so other signals keep the plain Fire
function module.watch(signal, endpoint, printing: boolean)
	const fire = signal.Fire
	if IS_SERVER then
		signal.Fire = function(self, player, ...)
			module.received(endpoint, printing, "fire", player, ...)
			return fire(self, player, ...)
		end
	else
		signal.Fire = function(self, ...)
			module.received(endpoint, printing, "fire", nil, ...)
			return fire(self, ...)
		end
	end
end

return module
