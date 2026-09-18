-- Better Signal by Raph

local freeRunnerThread = nil

local function acquireRunnerThreadAndCallEventHandler(fn, ...)
	local acquiredRunnerThread = freeRunnerThread
	freeRunnerThread = nil
	fn(...)
	freeRunnerThread = acquiredRunnerThread
end

-- Handlers arrive through coroutine.yield so their arguments never sit on this
-- thread's stack, which would keep them alive for the thread's whole lifetime.
local function runEventHandlerInFreeThread()
	while true do
		acquireRunnerThreadAndCallEventHandler(coroutine.yield())
	end
end

local function mergeArgs(bound, ...)
	local fired = table.pack(...)
	local total = bound.n + fired.n
	local merged = table.create(total)
	table.move(bound, 1, bound.n, 1, merged)
	table.move(fired, 1, fired.n, bound.n + 1, merged)
	return table.unpack(merged, 1, total)
end

export type Connection = {
	__type: string,
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
	Reconnect: (self: Connection) -> (),
	Destroy: (self: Connection) -> (),
}

export type Signal<T...> = {
	__type: string,
	Connect: ((self: Signal<T...>, callback: (T...) -> ()) -> Connection)
	& ((self: Signal<T...>, callback: (...any) -> (), ...any) -> Connection),
	Once: ((self: Signal<T...>, callback: (T...) -> ()) -> Connection)
	& ((self: Signal<T...>, callback: (...any) -> (), ...any) -> Connection),
	Fire: (self: Signal<T...>, T...) -> (),
	Wait: (self: Signal<T...>) -> T...,
	DisconnectAll: (self: Signal<T...>) -> (),
	Destroy: (self: Signal<T...>) -> (),
}

local Connection = {}
Connection.__index = Connection
Connection.__type = "Connection"

function Connection.new(signal, fn, ...)
	return setmetatable({
		Connected = false,
		_signal = signal,
		_fn = fn,
		_boundArgs = if select("#", ...) > 0 then table.pack(...) else nil,
		_next = false,
	}, Connection)
end

function Connection:Disconnect()
	if not self.Connected then
		return
	end
	self.Connected = false

	local signal = self._signal
	if signal._handlerListHead == self then
		signal._handlerListHead = self._next
	else
		local prev = signal._handlerListHead
		while prev and prev._next ~= self do
			prev = prev._next
		end
		if prev then
			prev._next = self._next
		end
	end
end

function Connection:Reconnect()
	local signal = self._signal
	if self.Connected or not signal then
		return
	end
	self.Connected = true
	self._next = signal._handlerListHead
	signal._handlerListHead = self
	signal:_scheduleFlush()
end

function Connection:Destroy()
	self:Disconnect()
	self._fn = nil
	self._boundArgs = nil
	self._signal = nil
end

local Signal = {}
Signal.__index = Signal
Signal.__type = "Signal"

function Signal.new<T...>(queue: boolean?): Signal<T...>
	return setmetatable({
		_handlerListHead = false,
		_queued = if queue then {} else nil,
	}, Signal)
end

local function drainQueue(signal)
	local pending = signal._queued
	if not pending or not signal._handlerListHead then
		return
	end
	signal._queued = nil
	for _, args in pending do
		signal:Fire(table.unpack(args, 1, args.n))
	end
end

function Signal:_scheduleFlush()
	local queued = self._queued
	if not queued then
		return
	end
	if #queued == 0 then
		self._queued = nil
	else
		task.defer(drainQueue, self)
	end
end

function Signal:Connect(fn, ...)
	local connection = Connection.new(self, fn, ...)
	connection:Reconnect()
	return connection
end

function Signal:Once(fn, ...)
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		fn(...)
	end, ...)
	return connection
end

function Signal:Fire(...)
	local queued = self._queued
	if queued then
		table.insert(queued, table.pack(...))
		return
	end

	local item = self._handlerListHead
	while item do
		if item.Connected then
			if not freeRunnerThread then
				freeRunnerThread = coroutine.create(runEventHandlerInFreeThread)
				coroutine.resume(freeRunnerThread)
			end
			local bound = item._boundArgs
			if bound then
				task.spawn(freeRunnerThread, item._fn, mergeArgs(bound, ...))
			else
				task.spawn(freeRunnerThread, item._fn, ...)
			end
		end
		item = item._next
	end
end

function Signal:Wait()
	local waitingCoroutine = coroutine.running()
	local connection
	connection = self:Connect(function(...)
		connection:Disconnect()
		if coroutine.status(waitingCoroutine) == "suspended" then
			task.spawn(waitingCoroutine, ...)
		end
	end)
	return coroutine.yield()
end

function Signal:DisconnectAll()
	local item = self._handlerListHead
	self._handlerListHead = false
	while item do
		item.Connected = false
		item = item._next
	end
end

function Signal:Destroy()
	local item = self._handlerListHead
	self:DisconnectAll()
	while item do
		local nextItem = item._next
		item:Destroy()
		item = nextItem
	end
	self._queued = nil
end

return Signal