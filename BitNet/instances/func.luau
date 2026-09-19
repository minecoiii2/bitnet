--!native
--!optimize 2

const Players = game:GetService("Players")
const RunService = game:GetService("RunService")
const IS_SERVER = RunService:IsServer()

const Bin = require(script.Parent.Parent.bin)
const binaries = require(script.Parent.Parent.binaries)
const registry = require(script.Parent.Parent.runtime.registry)
const constants = require(script.Parent.Parent.constants)
const codec = require(script.Parent.Parent.codec)
const assertAt = require(script.Parent.Parent.libs.assertAt)

const Bin_reserve = Bin.reserve
const Bin_tryWrite = Bin.tryWrite
const Bin_recover = Bin.recover
const markDirty = binaries.markDirty
const binFor = binaries.binFor
const getHeader = registry.getHeader
const rateLimitAllowed = registry.rateLimitAllowed
const buf_writeu8 = buffer.writeu8
const buf_writeu16 = buffer.writeu16
const buf_readu8 = buffer.readu8
const buf_readu16 = buffer.readu16
const table_unpack = table.unpack
const table_pack = table.pack
const table_create = table.create
const locate = codec.locate

const MAX_PENDING = constants.MAX_PENDING_PER_PLAYER
const MAX_CALLBACKS = constants.MAX_CALLBACKS_PER_PLAYER

const REQUEST_FLAG = 32768
const ERROR_FLAG = 16384
const REQID_SPACE = 16384

const CALLBACK_ERRORED = 1
const NO_CALLBACK = 2
const REFUSED = 3
const BAD_RESPONSE = 4
const ERROR_REASONS = {
	[CALLBACK_ERRORED] = "the callback errored",
	[NO_CALLBACK] = "no callback is set on the other side",
	[REFUSED] = "the request was refused by a rate limit or the callback cap",
	[BAD_RESPONSE] = "the callback returned something that could not be sent",
}

const playerCleanups: { (player: Player) -> () } = {}
const running: { [Player]: number } = {}
if IS_SERVER then
	Players.PlayerRemoving:Connect(function(player)
		running[player] = nil
		for _, clear in playerCleanups do
			clear(player)
		end
	end)
end

local freeRunner: thread? = nil
const function runAndRelease(fn, ...)
	const runner = freeRunner
	freeRunner = nil
	fn(...)
	freeRunner = runner
end
const function runnerLoop()
	while true do
		runAndRelease(coroutine.yield())
	end
end
const function spawnCallback(fn, ...)
	if not freeRunner then
		freeRunner = coroutine.create(runnerLoop)
		coroutine.resume(freeRunner)
	end
	task.spawn(freeRunner :: thread, fn, ...)
end

const module = {}

-- Define a remote function
--   options.Args      -- request payload
--   options.Returns   -- response payload
--   options.Timeout   -- seconds to wait for response (default: constants.DEFAULT_FUNC_TIMEOUT)
--   options.ValidateOutgoing -- check values against the schema before send (default: constants.VALIDATE_OUTGOING_TYPES)
--   options.RateLimit -- server-side gate
function module.new(options: {
	Args: any,
	Returns: any,
	Timeout: number?,
	ValidateOutgoing: boolean?,
	RateLimit: { calls: number, per: number }?,
	ValidateAcceptNonFinite: boolean?,
})
	const args = options.Args
	const returns = options.Returns
	const typecheck = if options.ValidateOutgoing == nil then constants.VALIDATE_OUTGOING_TYPES else options.ValidateOutgoing

	assertAt(args, "bitnet.func: options.Args is required", 2)
	assertAt(args.write and args.read,
		"bitnet.func: options.Args is not a compiled bitnet type", 2)
	assertAt(returns, "bitnet.func: options.Returns is required", 2)
	assertAt(returns.write and returns.read,
		"bitnet.func: options.Returns is not a compiled bitnet type", 2)

	assertAt(options.Direction == nil,
		"bitnet.func: options.Direction no longer exists, every func works in both directions", 2)
	assertAt(options.Typecheck == nil, "bitnet.func: options.Typecheck is now ValidateOutgoing", 2)

	const timeoutSeconds = options.Timeout or constants.DEFAULT_FUNC_TIMEOUT

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
		_acceptNonFinite = if options.ValidateAcceptNonFinite == nil
			then not constants.VALIDATE_DEFAULT_REJECT_NON_FINITE
			else options.ValidateAcceptNonFinite,

		callback = nil,
	}

	registry.register(self)
	const id = self.id

	self._diagnose = function(buf, cursor, context)
		const word = buf_readu16(buf, cursor)
		if word >= REQUEST_FLAG + ERROR_FLAG then
			return "request", "request id has the error bit set"
		elseif word >= ERROR_FLAG and word < REQUEST_FLAG then
			return "error response", if pcall(buf_readu8, buf, cursor + 2) then nil else "missing its reason code"
		end
		const request = word >= REQUEST_FLAG
		const path, reason = locate(if request then args else returns, buf, cursor + 2, context, "")
		const side = if request then "request" else "response"
		return (if path == "" then side else `{side} {path}`), reason
	end

	self._skip = function(buf, cursor, context)
		const word = buf_readu16(buf, cursor)
		if word >= REQUEST_FLAG then
			if word >= REQUEST_FLAG + ERROR_FLAG then
				error("bitnet: request id has the error bit set", 0)
			end
			const _, nextCursor = args.read(buf, cursor + 2, context)
			return nextCursor
		elseif word >= ERROR_FLAG then
			buf_readu8(buf, cursor + 2)
			return cursor + 3
		end
		const _, nextCursor = returns.read(buf, cursor + 2, context)
		return nextCursor
	end

	local hdrSize = 0
	local hdrLow = 0
	local hdrHigh = 0

	const argsCostly = args._costly == true
	const returnsCostly = returns._costly == true
	const argsMarked = args._sideChannel ~= false
	const returnsMarked = returns._sideChannel ~= false
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
	local warnedNoCallback = false

	-- writes the frame id and the u16 word, returning where the payload goes
	const function beginFrame(bin, word: number, payload: number): number
		if hdrSize == 0 then
			hdrSize, hdrLow, hdrHigh = getHeader(self)
		end
		const c0 = bin.cursor
		if c0 == bin.safeCursor then
			Bin_recover(bin)
		end
		const need = hdrSize + 2 + payload
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
		buf_writeu16(b, c0 + hdrSize, word)
		return c0 + hdrSize + 2
	end

	const function writeFrame(bin, word: number, schema, costly: boolean, marked: boolean, value, hint: number): number
		const payloadAt = beginFrame(bin, word, if costly then hint else (schema.size or schema.sizeOf(value)))
		const a0 = bin.amount
		const r0 = bin.refCount
		if costly then
			const c1 = Bin_tryWrite(bin, payloadAt, a0, r0, schema.write, value)
			bin.cursor = c1
			return c1 - payloadAt
		end
		if marked then
			bin.safeCursor = bin.cursor
			bin.safeAmount = a0
			bin.safeValue = bin.value
			bin.safeRefs = r0
		end
		bin.cursor = schema.write(bin.buffer, payloadAt, value, bin)
		return hint
	end

	const function writeError(bin, reqid: number, code: number)
		const at = beginFrame(bin, reqid + ERROR_FLAG, 1)
		buf_writeu8(bin.buffer, at, code)
		bin.cursor = at + 1
	end

	const function takeReqId(): number
		for _ = 1, REQID_SPACE do
			const reqid = nextReqId
			nextReqId = (reqid + 1) % REQID_SPACE
			if pending[reqid] == nil then
				return reqid
			end
		end
		error(`bitnet.func #{id}: all {REQID_SPACE} request ids are waiting on a response`, 3)
	end

	const function expireServerInvoke(reqid: number, thread: thread)
		if pending[reqid] == thread then
			pending[reqid] = nil
			task.spawn(thread, false, "timeout")
		end
	end

	const function expireClientInvoke(reqid: number, thread: thread)
		const entry = pending[reqid]
		if entry and entry.thread == thread then
			pending[reqid] = nil
			outstanding[entry.player] = (outstanding[entry.player] or 1) - 1
			task.spawn(thread, false, "timeout")
		end
	end

	function self:InvokeServer(...)
		if IS_SERVER then
			error(`bitnet.func #{id}:InvokeServer called on server`, 2)
		end
		const value = if isTuple then {...} else (...)

		if typecheck then
			if not isTuple and select('#', ...) > 1 then
				error(`bitnet.func #{id} outgoing validation failed: too many values`, 2)
			end
			const ok, err = args.check(value)
			if not ok then
				error(`bitnet.func #{id} outgoing validation failed: {err}`, 2)
			end
		end

		const reqid = takeReqId()
		argsHint = writeFrame(binaries.globalReliable, reqid + REQUEST_FLAG, args, argsCostly, argsMarked, value, argsHint)

		const thread = coroutine.running()
		pending[reqid] = thread

		if hasTimeout then
			task.delay(timeout, expireServerInvoke, reqid, thread)
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
		const bin = binaries.playersReliable[player] or binFor(player, true)
		if not bin then
			error(`bitnet.func #{id}:InvokeClient has no bin for {tostring(player)}`, 2)
		end

		const value = if isTuple then {...} else (...)

		if typecheck then
			if not isTuple and select('#', ...) > 1 then
				error(`bitnet.func #{id} outgoing validation failed: too many values`, 2)
			end
			const ok, err = args.check(value)
			if not ok then
				error(`bitnet.func #{id} outgoing validation failed: {err}`, 2)
			end
		end

		const used = outstanding[player] or 0
		if used >= MAX_PENDING then
			error(`bitnet.func #{id}: {tostring(player)} already has {used} outstanding invokes`, 2)
		end

		const reqid = takeReqId()
		if bin.cursor == 0 then
			markDirty(bin)
		end
		argsHint = writeFrame(bin, reqid + REQUEST_FLAG, args, argsCostly, argsMarked, value, argsHint)

		const thread = coroutine.running()
		pending[reqid] = { thread = thread, player = player }
		outstanding[player] = used + 1

		task.delay(timeout, expireClientInvoke, reqid, thread)

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

	const function replyBin(player: Player?)
		if not player then
			return binaries.globalReliable
		end
		const bin = binaries.playersReliable[player] or binFor(player, true)
		if bin and bin.cursor == 0 then
			markDirty(bin)
		end
		return bin
	end

	const function sendResponse(reqid: number, response, player: Player?)
		const bin = replyBin(player)
		if bin then
			returnsHint = writeFrame(bin, reqid, returns, returnsCostly, returnsMarked, response, returnsHint)
		end
	end

	const function sendError(reqid: number, code: number, player: Player?)
		const bin = replyBin(player)
		if bin then
			writeError(bin, reqid, code)
		end
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

	const function answer(value, reqid: number, player: Player?)
		const callback = self.callback
		if callback == nil then
			if not warnedNoCallback then
				warnedNoCallback = true
				warn(`bitnet.func #{id} has no callback on this side, so every invoke of it here fails`)
			end
			sendError(reqid, NO_CALLBACK, player)
			return
		end
		const ok, response = runCallback(callback, value, player)
		if not ok then
			sendError(reqid, CALLBACK_ERRORED, player)
			return
		end
		if typecheck then
			const vok, verr = returns.check(response)
			if not vok then
				warn(`bitnet.func #{id} returns outgoing validation failed: {verr}`)
				sendError(reqid, BAD_RESPONSE, player)
				return
			end
		end
		const sent, err = pcall(sendResponse, reqid, response, player)
		if not sent then
			warn(`bitnet.func #{id} could not send its response: {tostring(err)}`)
			sendError(reqid, BAD_RESPONSE, player)
		end
	end

	if IS_SERVER then
		const function answerPlayer(value, reqid: number, player: Player)
			const ok, err = pcall(answer, value, reqid, player)
			const inFlight = running[player]
			if inFlight then
				running[player] = if inFlight > 1 then inFlight - 1 else nil
			end
			if not ok then
				warn(`bitnet.func #{id} failed to answer {player.Name}: {tostring(err)}`)
			end
		end

		const function settle(reqid: number, player: Player, ok: boolean, result)
			const entry = pending[reqid]
			if entry and entry.player == player then
				pending[reqid] = nil
				outstanding[player] = (outstanding[player] or 1) - 1
				task.spawn(entry.thread, ok, result)
			end
		end

		self._handle = function(buf, cursor, context, player)
			const word = buf_readu16(buf, cursor)
			if word >= REQUEST_FLAG then
				const reqid = word - REQUEST_FLAG
				if reqid >= REQID_SPACE then
					error("bitnet: request id has the error bit set", 0)
				end
				const value, nextCursor = args.read(buf, cursor + 2, context)
				const inFlight = running[player] or 0
				if (rateLimited and not rateLimitAllowed(self, player)) or inFlight >= MAX_CALLBACKS then
					sendError(reqid, REFUSED, player)
					return nextCursor
				end
				running[player] = inFlight + 1
				spawnCallback(answerPlayer, value, reqid, player)
				return nextCursor
			end
			if word >= ERROR_FLAG then
				const code = buf_readu8(buf, cursor + 2)
				settle(word - ERROR_FLAG, player, false, ERROR_REASONS[code] or `error {code}`)
				return cursor + 3
			end
			const value, nextCursor = returns.read(buf, cursor + 2, context)
			settle(word, player, true, value)
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
		const function settle(reqid: number, ok: boolean, result)
			const thread = pending[reqid]
			if thread then
				pending[reqid] = nil
				task.spawn(thread, ok, result)
			end
		end

		self._handle = function(buf, cursor, context)
			const word = buf_readu16(buf, cursor)
			if word >= REQUEST_FLAG then
				const value, nextCursor = args.read(buf, cursor + 2, context)
				spawnCallback(answer, value, word - REQUEST_FLAG, nil)
				return nextCursor
			end
			if word >= ERROR_FLAG then
				const code = buf_readu8(buf, cursor + 2)
				settle(word - ERROR_FLAG, false, ERROR_REASONS[code] or `error {code}`)
				return cursor + 3
			end
			const value, nextCursor = returns.read(buf, cursor + 2, context)
			settle(word, true, value)
			return nextCursor
		end
	end

	return self
end

return module