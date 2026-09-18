--!native
--!optimize 2

-- Functions: request/response, client -> server only.
-- Shape: [u8 or varint id][u16 reqid][payload]
--   args (client -> server, the invoke)
--   returns (server -> client, the response)

const Players = game:GetService("Players")
const RunService = game:GetService("RunService")
const IS_SERVER = RunService:IsServer()

const Bin = require(script.Parent.Parent.bin)
const binaries = require(script.Parent.Parent.binaries)
const registry = require(script.Parent.Parent.runtime.registry)
const constants = require(script.Parent.Parent.constants)
const assertAt = require(script.Parent.Parent.libs.assertAt)

const Bin_reserve = Bin.reserve
const Bin_tryWrite = Bin.tryWrite
const markDirty = binaries.markDirty
const getHeader = registry.getHeader
const rateLimitAllowed = registry.rateLimitAllowed
const buf_writeu8 = buffer.writeu8
const buf_writeu16 = buffer.writeu16
const buf_readu16 = buffer.readu16
const table_unpack = table.unpack
const table_pack = table.pack
const table_create = table.create

const DEFAULT_TIMEOUT = constants.DEFAULT_FUNC_TIMEOUT
const MAX_PENDING = constants.MAX_PENDING_PER_PLAYER

const REQUEST_FLAG = 32768
const REQID_SPACE = 32768

-- one connection for the whole module rather than one per func
const playerCleanups: { (player: Player) -> () } = {}
if IS_SERVER then
	Players.PlayerRemoving:Connect(function(player)
		for _, clear in playerCleanups do
			clear(player)
		end
	end)
end

const module = {}

-- Define a remote function
--   options.Args      -- request payload
--   options.Returns   -- response payload
--   options.Timeout   -- seconds to wait for response (default: constants.DEFAULT_FUNC_TIMEOUT)
--   options.Typecheck -- rruntime structural validation before send (default: constants.DEFAULT_TYPECHECK)
--   options.RateLimit -- server-side gate
function module.new(options: {
	Args: any,
	Returns: any,
	Timeout: number?,
	Typecheck: boolean?,
	RateLimit: { calls: number, per: number }?,
})
	const args = options.Args
	const returns = options.Returns
	const typecheck = if options.Typecheck == nil then constants.DEFAULT_TYPECHECK else options.Typecheck

	assertAt(args, "bitnet.func: options.Args is required", 2)
	assertAt(args.write and args.read,
		"bitnet.func: options.Args is not a compiled bitnet type", 2)
	assertAt(returns, "bitnet.func: options.Returns is required", 2)
	assertAt(returns.write and returns.read,
		"bitnet.func: options.Returns is not a compiled bitnet type", 2)

	assertAt(options.Direction == nil,
		"bitnet.func: options.Direction no longer exists, every func works in both directions", 2)

	const timeoutSeconds = options.Timeout or DEFAULT_TIMEOUT

	const isTuple = args._isTuple == true
	
	const self = {
		kind = "func",
		id = 0,
		args = args,
		returns = returns,
		timeout = timeoutSeconds,
		typecheck = typecheck,
		rateLimit = options.RateLimit,
		rateState = if options.RateLimit
			then setmetatable({}, { __mode = "k" })
			else nil,
		argsIsTuple = isTuple,
		argsArity = args._arity,
		returnsIsTuple = returns._isTuple == true,
		returnsArity = returns._arity,
		_pending = {},

		callback = nil,
	}

	registry.register(self)
	const id = self.id
	local hdrSize = 0
	local hdrLow = 0
	local hdrHigh = 0

	const argsCostly = args._costly == true
	const returnsCostly = returns._costly == true
	const argsArity = args._arity
	const returnsIsTuple = returns._isTuple == true
	const returnsArity = returns._arity
	const rateLimited = options.RateLimit ~= nil
	const pending = self._pending
	const outstanding = if IS_SERVER then setmetatable({}, { __mode = "k" }) else nil
	const timeout = self.timeout
	const hasTimeout = math.isfinite(timeout) and timeout > 0
	local nextReqId = 0
	local argsHint = 64
	local returnsHint = 64

	const function writeFrame(bin, reqid: number, schema, costly: boolean, value, hint: number): number
		if hdrSize == 0 then
			hdrSize, hdrLow, hdrHigh = getHeader(self)
		end
		const c0 = bin.cursor
		const a0 = bin.amount
		const r0 = bin.refCount
		const need = if costly
			then hdrSize + 2 + hint
			else hdrSize + 2 + (schema.size or schema.sizeOf(value))
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

		buf_writeu16(b, c0 + hdrSize, reqid)
		const payloadAt = c0 + hdrSize + 2
		if costly then
			const c1 = Bin_tryWrite(bin, payloadAt, a0, r0, schema.write, value)
			bin.cursor = c1
			return c1 - payloadAt
		end
		bin.cursor = schema.write(b, payloadAt, value, bin)
		return hint
	end

	function self:InvokeServer(...)
		if IS_SERVER then
			error(`bitnet.func #{id}:InvokeServer called on server`, 2)
		end
		const value = if isTuple then {...} else (...)

		if typecheck then
			if not isTuple and select('#', ...) > 1 then
				error(`bitnet.func #{id} tuple typecheck failed: too many values`)
			end
			const ok, err = args.check(value)
			if not ok then
				error(`bitnet.func #{id} typecheck failed: {err}`, 2)
			end
		end

		const reqid = nextReqId
		nextReqId = (nextReqId + 1) % REQID_SPACE

		const thread = coroutine.running()
		pending[reqid] = thread

		argsHint = writeFrame(binaries.globalReliable, reqid + REQUEST_FLAG, args, argsCostly, value, argsHint)

		if hasTimeout then
			task.delay(timeout, function()
				if pending[reqid] then
					pending[reqid] = nil
					task.spawn(thread, false, "timeout")
				end
			end)
		end

		const ok, resultOrErr = coroutine.yield()
		if not ok then
			error(`bitnet.func #{id}: {resultOrErr}`, 2)
		end

		if returnsIsTuple then
			return table_unpack(resultOrErr, 1, returnsArity)
		else
			return resultOrErr
		end
	end

	function self:InvokeClient(player: Player, ...)
		if not IS_SERVER then
			error(`bitnet.func #{id}:InvokeClient called on client`, 2)
		end
		if not hasTimeout then
			error(`bitnet.func #{id}:InvokeClient needs a finite positive Timeout; a client that never answers would park this thread forever`, 2)
		end
		const bin = binaries.playersReliable[player]
		if not bin then
			error(`bitnet.func #{id}:InvokeClient has no bin for {tostring(player)}`, 2)
		end

		const value = if isTuple then {...} else (...)

		if typecheck then
			if not isTuple and select('#', ...) > 1 then
				error(`bitnet.func #{id} tuple typecheck failed: too many values`)
			end
			const ok, err = args.check(value)
			if not ok then
				error(`bitnet.func #{id} typecheck failed: {err}`, 2)
			end
		end

		const used = outstanding[player] or 0
		if used >= MAX_PENDING then
			error(`bitnet.func #{id}: {tostring(player)} already has {used} outstanding invokes`, 2)
		end

		const reqid = nextReqId
		nextReqId = (nextReqId + 1) % REQID_SPACE

		const thread = coroutine.running()
		pending[reqid] = { thread = thread, player = player }
		outstanding[player] = used + 1

		if bin.cursor == 0 then
			markDirty(bin)
		end
		argsHint = writeFrame(bin, reqid + REQUEST_FLAG, args, argsCostly, value, argsHint)

		task.delay(timeout, function()
			const entry = pending[reqid]
			if entry then
				pending[reqid] = nil
				outstanding[entry.player] = (outstanding[entry.player] or 1) - 1
				task.spawn(entry.thread, false, "timeout")
			end
		end)

		const ok, resultOrErr = coroutine.yield()
		if not ok then
			error(`bitnet.func #{id}: {resultOrErr}`, 2)
		end

		if returnsIsTuple then
			return table_unpack(resultOrErr, 1, returnsArity)
		else
			return resultOrErr
		end
	end

	function self:SetCallback(cb)
		self.callback = cb
	end
	function self:SetServerCallback(cb)
		if not IS_SERVER then
			error(`bitnet.func #{id}:SetServerCallback called on client`, 2)
		end
		self.callback = cb
	end
	function self:SetClientCallback(cb)
		if IS_SERVER then
			error(`bitnet.func #{id}:SetClientCallback called on server`, 2)
		end
		self.callback = cb
	end

	const function respond(player: Player, reqid: number, response)
		const respBin = binaries.playersReliable[player]
		if not respBin then return end
		if respBin.cursor == 0 then
			markDirty(respBin)
		end
		returnsHint = writeFrame(respBin, reqid, returns, returnsCostly, response, returnsHint)
	end

	const function respondToServer(reqid: number, response)
		returnsHint = writeFrame(binaries.globalReliable, reqid, returns, returnsCostly, response, returnsHint)
	end

	const function runCallback(callback, value, player: Player?)
		if returnsIsTuple then
			local results
			if isTuple then
				results = if player
					then table_pack(pcall(callback, player, table_unpack(value, 1, argsArity)))
					else table_pack(pcall(callback, table_unpack(value, 1, argsArity)))
			else
				results = if player
					then table_pack(pcall(callback, player, value))
					else table_pack(pcall(callback, value))
			end
			if not results[1] then
				warn(`bitnet: func #{id} callback errored: {tostring(results[2])}`)
				return false
			end
			const response = table_create(returnsArity)
			for i = 1, returnsArity do
				response[i] = results[i + 1]
			end
			return true, response
		end

		local ok, result
		if isTuple then
			if player then
				ok, result = pcall(callback, player, table_unpack(value, 1, argsArity))
			else
				ok, result = pcall(callback, table_unpack(value, 1, argsArity))
			end
		elseif player then
			ok, result = pcall(callback, player, value)
		else
			ok, result = pcall(callback, value)
		end
		if not ok then
			warn(`bitnet: func #{id} callback errored: {tostring(result)}`)
			return false
		end
		return true, result
	end

	const function answer(value, reqid: number, nextCursor: number, player: Player?): number
		const callback = self.callback
		if callback == nil then
			warn(`bitnet: func {id} has no SetCallback handler`)
			return nextCursor
		end
		const ok, response = runCallback(callback, value, player)
		if not ok then
			return nextCursor
		end
		if typecheck then
			const vok, verr = returns.check(response)
			if not vok then
				warn(`bitnet: func #{id} returns typecheck failed: {verr}`)
				return nextCursor
			end
		end
		if player then
			respond(player, reqid, response)
		else
			respondToServer(reqid, response)
		end
		return nextCursor
	end

	if IS_SERVER then
		self._handle = function(buf, cursor, context, player)
			const word = buf_readu16(buf, cursor)
			if word >= REQUEST_FLAG then
				const value, nextCursor = args.read(buf, cursor + 2, context)
				if rateLimited and not rateLimitAllowed(self, player) then
					return nextCursor
				end
				return answer(value, word - REQUEST_FLAG, nextCursor, player)
			end
			const value, nextCursor = returns.read(buf, cursor + 2, context)
			const entry = pending[word]
			if entry and entry.player == player then
				pending[word] = nil
				outstanding[player] = (outstanding[player] or 1) - 1
				task.spawn(entry.thread, true, value)
			end
			return nextCursor
		end

		table.insert(playerCleanups, function(player)
			for reqid, entry in pending do
				if entry.player == player then
					pending[reqid] = nil
					task.spawn(entry.thread, false, "player left")
				end
			end
			outstanding[player] = nil
		end)
	else
		self._handle = function(buf, cursor, context)
			const word = buf_readu16(buf, cursor)
			if word >= REQUEST_FLAG then
				const value, nextCursor = args.read(buf, cursor + 2, context)
				return answer(value, word - REQUEST_FLAG, nextCursor, nil)
			end
			const value, nextCursor = returns.read(buf, cursor + 2, context)
			const thread = pending[word]
			if thread then
				pending[word] = nil
				task.spawn(thread, true, value)
			end
			return nextCursor
		end
	end

	return self
end

return module