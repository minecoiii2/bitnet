--[[
# Bitnet

(readme meant for LLMs/Agents)

Buffer-based networking library for Roblox. Replaces RemoteEvent/RemoteFunction with batched, type-checked wire frames over two shared remotes, using a main buffer plus refs and packed-boolean side channels.

## Module layout
ReplicatedStorage.BitNet              -- main module, returns init(config?) -> { types, event, func, signal, OnRejected }
├── codec                             -- type primitives + combinators, strict readers, rejection locator
├── bin                               -- per-bin buffer, refs and boolean state; grow/retry, bool packing, snapshots
├── binaries                          -- global + per-player bins, dirty tracking
├── constants                         -- config defaults; init writes the config over them
├── instances/
│   ├── event                         -- event.new
│   ├── func                          -- func.new
│   └── signal                        -- signal.new (recycled runner thread, optional pre-connect queue)
├── runtime/
│   ├── registry                      -- sequential id minting, frame headers, rate limiting
│   ├── remotes                       -- BitnetReliable + BitnetUnreliable
│   ├── players                       -- u8 player ids for types.player, published as an attribute
│   └── dispatch                      -- Heartbeat send loop + receive parser
├── libs/
│   ├── hash                          -- FNV-1a u32
│   ├── assertAt                      -- error at user-specified stack level
│   └── getNearbyPlayers              -- players within range, for streamed fires
└── types                             -- Luau type definitions (Bitnet, BitnetTypes, Config, ServerEvent, ServerFunction)

## Public API

### Setup

The module returns an init function. Call it exactly once per machine, from the shared module that defines every event and func:

```lua
-- ReplicatedStorage.Networking
local BitNet = require(ReplicatedStorage.BitNet)({
	VALIDATE_MAX_DECOMPRESSED_BYTES = 262144,
})
```

- `config` is optional. Each key overrides the default of the same name (see Config) and a key left out keeps its default. `types.Config` lists them; keys aren't checked at runtime, so a misspelled one is silently ignored.
- Init writes the config first and only then loads the rest of BitNet, which copies the values as it loads. That is why settings such as `VALIDATE_INCOMING_TYPES` cost nothing per frame, and why nothing can change them afterwards.
- A second call errors with `Bitnet already initialized`. Everything else gets BitNet from the shared module, or from a module that caches the one result.
- Both sides run the shared module, so both get the same config. Some defaults differ per machine (`VALIDATE_INCOMING_TYPES` is on only on the server, `VALIDATE_OUTGOING_TYPES` only in Studio), and passing a value applies it on both sides; branch on `RunService:IsServer()` to set one side only.

### Exports

The table init returns:

| Field        | Description                                                                 |
| ------------ | --------------------------------------------------------------------------- |
| `types`      | Table of all type primitives and combinators.                               |
| `event(opts)`| Creates a new event. Returns a `ServerEvent<A...>`.                         |
| `func(opts)` | Creates a new function. Returns a `ServerFunction<A..., R...>`.             |
| `signal()`   | Creates a standalone Signal (local pub-sub, not networked).                 |
| `OnRejected` | Signal fired `(player?, id?, reason)` when a validating receiver rejects incoming data. |

### Types

| Type | Bytes | Notes |
| ---- | ----- | ----- |
| `u8` `u16` `u24` `u32` | 1 2 3 4 | Unsigned integers. |
| `i8` `i16` `i24` `i32` | 1 2 3 4 | Signed integers. |
| `f24` `f32` `f64` | 3 4 8 | `f24` is an f32 with the low 8 mantissa bits dropped, by truncation, so its relative error reaches 3e-5 and is biased toward zero. `number` aliases `f64`. |
| `bool` | 0 | One bit in the boolean side channel. |
| `string` `buffer` | 1-5 + len | Varint byte-length prefix: one byte through 127, five through the u32 max. |
| `uuid` | 16 | Canonical lowercase unbraced 36-char form only; `check` rejects anything else. |
| `vec2` `vec3` | 8 12 | f32 per axis. |
| `vec2i16(scale?)` `vec3i16(scale?)` | 4 6 | Fixed point, i16 count of `1/scale` studs. Default scale 100, so ±327 studs. |
| `color3` | 3 | u8 RGB. |
| `cframe` | 18 | f32 position, u16 orientation angles. |
| `cframelong` | 24 | f32 position and f32 orientation angles. |
| `brickcolor` | 2 | `BrickColor.Number`. |
| `numberrange` | 8 | Two f32. |
| `udim` `udim2` | 4 8 | i16 Scale thousandths + i16 Offset per axis. Scale ±32.767, Offset ±32767. |
| `numbersequence` | 1 + 4n or 1 + 12n | Compact or full per value; one bit in the boolean channel says which. |
| `colorsequence` | 1 + 7n | u8 count, then f32 Time and a u8 RGB triple. Max 255 keypoints. |
| `nothing` | 0 | Always nil. |
| `ref` `unknown` | 0 | Ride the refs side channel and accept nil. `ref` carries any value a RemoteEvent can. `unknown` aliases `ref`. |
| `player` | 1 | The player's u8 id, which the server assigns and publishes as an attribute. Nil, or a player who has left, reads as nil. `auto` still sends Players as refs. |
| `auto` | 1 + payload | Tagged dynamic value, see Gotchas. |

The narrow types (`u24`, `i24`, `f24`, `vec*i16`, `cframe`) trade CPU for bytes: buffer reads and writes cost the same at every width, so narrowing only ever adds work. Reach for them when bandwidth is the binding constraint, not by default.

**Combinators:**
- `struct(format)` — keyed table. Fields are hash-sorted, so source order does not matter.
- `array(value)` — sequential array, varint count.
- `map(key, value)` — k/v table. Count is backfilled after the entries, so it is capped at 16,383.
- `instance(...className)` — an Instance on the refs channel, 0 bytes in the main buffer. With class names, outgoing and incoming validation require `:IsA` of at least one of them, so subclasses pass; with none, any Instance. Nil is always accepted, and an Instance the receiver can't see (streamed out, server-only) arrives as nil. Compiled once per class list.
- `optional(value)` — nullable. Presence is a bit in the boolean channel; a nil writes nothing to the main buffer.
- `tuple(...)` — variadic.
- `enum(enumObject)` — Roblox EnumItem, e.g. `enum(Enum.KeyCode)`. 1, 2 or 4 bytes by the enum's largest value. Lookup tables are built once per Enum and shared.
- `enumFromKeys(t)` / `enumFromValues(t)` — interned string enums over a known set, 1, 2 or 4 bytes by symbol count. Interns the table's keys or its values respectively; both sort lexicographically, so the two are interchangeable for the same set. Strings only, closed once compiled, cached per source table.
- `compress(value, level?)` — Zstd-wraps any type, emitting whichever of the raw and compressed forms is smaller, so it can never inflate the wire. `level` defaults to -2; under 128 bytes stays raw.

### Events

`event(options)` where options is:

| Field       | Type                              | Default | Description                                    |
| ----------- | --------------------------------- | ------- | ---------------------------------------------- |
| `Args`      | compiled type                     | required | Schema for the payload.                       |
| `Reliable`  | `boolean?`                        | `true`  | Reliable or unreliable channel.                |
| `ValidateOutgoing` | `boolean?`                 | `IS_STUDIO` | Check values against the schema before send. |
| `RateLimit` | `{calls: number, per: number}?`   | nil     | Server-side gate on incoming client fires.     |
| `ValidateAcceptNonFinite` | `boolean?` | nil | Overrides `VALIDATE_DEFAULT_REJECT_NON_FINITE` for this event. |

**Methods:**
- `:FireServer(...)` — client → server
- `:FireClient(player, ...)` — server → one client
- `:FireAllClients(...)` — server → all clients
- `:FireClientsStreamed(at, range, ...)` / `:FireClientsStreamedWithExclusion(at, range, exclude, ...)` — server → players whose HumanoidRootPart is within `range` of `at`
- `.OnReceived` — Signal fired with `(player, ...payload)` on the server and `(...payload)` on the client. `.OnServerEvent` and `.OnClientEvent` are the same signal under other names.

**Client events buffer until someone listens.** Fires arriving before the first handler connects are queued, then drained on the next defer to whatever is connected at that moment. After that the queue is gone for good and fires with no handler are dropped, as they always are on the server. A `:Once` or `:Wait` as the first listener takes the oldest buffered fire and the rest of the backlog is dropped.

### Funcs

`func(options)`:

| Field       | Type                              | Default | Description                                    |
| ----------- | --------------------------------- | ------- | ---------------------------------------------- |
| `Args`      | compiled type                     | required | Schema for the request payload.               |
| `Returns`   | compiled type                     | required | Schema for the response payload.               |
| `Timeout`   | `number?`                         | `7`     | Seconds to wait for response before erroring. `math.huge` or `0` waits forever. |
| `ValidateOutgoing` | `boolean?`                 | `IS_STUDIO` | Check args and returns against their schemas before send. |
| `RateLimit` | `{calls: number, per: number}?`   | nil     | Server-side gate on incoming invokes.          |
| `ValidateAcceptNonFinite` | `boolean?` | nil | Overrides `VALIDATE_DEFAULT_REJECT_NON_FINITE` for this func, requests and responses alike. |

**Methods:**
- `:InvokeServer(...)` — called on the client. Yields until the response or the timeout; raises on either failure.
- `:InvokeClient(player, ...)` — called on the server. Same yielding contract.
- `:SetCallback(fn)` — set on whichever side *answers*. Both sides may set one, since either can be invoked: the server's callback receives `(player, ...args) -> ...returns`, the client's receives `(...args) -> ...returns` with no player argument.
- `:SetServerCallback(fn)` / `:SetClientCallback(fn)` — the same, but raise if called on the wrong side.

**Every func works in both directions.** Each frame carries a u16 word whose top bit says request or response, leaving a 15-bit request id. That is what lets both directions be in flight on the same func at once without their ids colliding — 32,767 outstanding per side. Funcs are always reliable.

**Invoking a client is hostile ground**, because the client decides whether an answer ever comes back. Three things make it survivable, and they are load-bearing rather than polish:
- `:InvokeClient` **requires a finite positive `Timeout`** and raises without one, since an untimed invoke would park a server thread and leak its pending entry for as long as the server runs. `:InvokeServer` carries no such requirement, so an untimed func stays legal as long as nothing invokes a client with it.
- Each player may hold at most `MAX_PENDING_PER_PLAYER` outstanding invokes; past that `:InvokeClient` raises rather than letting one stalling client accumulate server threads.
- A response is only accepted from the player the request was sent to, so one player cannot answer another's invoke. A player leaving fails their pending invokes immediately instead of making the server wait out the timeout.

A client with no callback, or whose callback errors, simply lets the invoke time out. There is no distinct error response on the wire; the second free reqid bit is where one would go.

### Signal

`signal()` returns a `Signal<T...>`:

- `:Fire(...)`
- `:Connect(fn, ...)` → `Connection`. Extra arguments are bound and passed before the fired ones.
- `:Once(fn, ...)` → `Connection`
- `:Wait()` → `...`
- `:DisconnectAll()` — disconnects every handler; each can still `:Reconnect()`.
- `:Destroy()` — disconnects and releases every handler.

Connection: `.Connected`, `:Disconnect()`, `:Reconnect()`, `:Destroy()`. Only `:Destroy()` is final.

Handlers run on a recycled runner thread, newest connection first.

### Validation

With `VALIDATE_INCOMING_TYPES` on, which is the default on the server, the codec swaps in strict readers when BitNet initializes. A machine with it off keeps the lean readers and pays nothing. A frame that fails is rejected: the rest of that batch is dropped, a warning names the endpoint, sender, field path and reason, and `OnRejected` fires. Frames earlier in the same batch were already delivered.

What strict decoding enforces:
- **Nothing is allocated from a bare count.** Every array, map, string, buffer, `auto` array or map and `compress` length is checked against what the sender actually sent before anything is created, using the element's cheapest encoding per channel. Ref-only elements get 1,024 spare refs per batch, for Instances that arrive as nil; zero-size elements share 1,024 per batch.
- **`instance` fields hold nil or an Instance that `:IsA` one of their class names.**
- **Floats are finite**, across f24/f32/f64, vectors, CFrames, NumberRange and sequence keypoints, unless `VALIDATE_DEFAULT_REJECT_NON_FINITE` is off or the endpoint sets `ValidateAcceptNonFinite`.
- **`compress` inflation is budgeted.** `DecompressBuffer` sizes its output from each zstd frame's declared content size and refuses to exceed it, so those sizes are summed from the frame headers and charged against `VALIDATE_MAX_DECOMPRESSED_BYTES` per batch before decompressing. The decoded value must then use the payload exactly.
- **Structure holds**: `auto` nests at most 128 deep, map counts stay within 16,383, map keys are never nil or NaN, the boolean side channel can't run dry, and batches whose remote arguments aren't `(buffer, table?, buffer?)` are rejected outright.

Finding the field is slow-path only. On failure the batch is replayed without firing anything; frames that decoded before decode again, so the failing frame is reached in the same state and walked field by field, e.g. `bitnet.event #14 from Player1 rejected: arg 2.pos: Vector3 is not finite (inf, 0, 0)`.

This checks types and bounds, not meaning. Whether an id exists, whether an Instance belongs to the sender, or whether a position is reachable stays with your handlers.

## How it works

- **Framing.** Each fire writes `[id][payload]` into a bin. `runtime.registry` mints IDs sequentially in registration order, up to 65,535. Under 255 endpoints they are one byte, otherwise varint. The format locks on first network use, so everything must register before any fire.
- **Batching.** All fires within one Heartbeat coalesce into one RemoteEvent fire per (channel, target), over two shared remotes. On the server a bin joins a dirty list when its cursor leaves 0; the client checks its two global bins directly.
- **Three channels per send.** The main buffer is argument 1, the refs array argument 2, the packed boolean buffer argument 3.
- **Refs channel.** Instances and `ref` values ride as real Lua values and take no bytes in the main buffer. Writers append in order, readers consume in the same order, counted by `refCount`. Nil is stored as `false` so the array never has holes; an `instance` can't be `false`, while a falsy `ref` spends one boolean-channel bit telling nil from false.
- **Player ids.** `runtime.players` hands out ids 1-255 round robin (0 is nil) on PlayerAdded, or on first write if a handler beat it there, publishes them as the `PLAYER_ID_ATTRIBUTE` attribute and frees them on PlayerRemoving. Clients mirror the map from the attribute, so a client writing a player whose attribute hasn't replicated yet raises.
- **Tuple fast path.** Events whose `Args` is a tuple of 2 to 6 values fire and receive them as plain arguments, with no packed table on either side. Larger tuples pack into a table. Funcs always pack.
- **Dispatch.** Every entry exposes one prebuilt `_handle(buf, cursor, context, player)`; `runtime.dispatch` just calls it, with one pcall per batch.
- **Streamed fires.** Validated and encoded once into a scratch bin, then copied into each nearby player's bin.
- **Unreliable chunking.** Combined main, boolean and ref payloads exceeding `MAX_UNRELIABLE_BYTES` split on fire boundaries into multiple sends. Refs count against the cap at `UNRELIABLE_REF_BYTES` each, and each chunk carries only its own refs. A single fire over the cap is dropped with a warning.
- **Boolean channel.** Booleans, `optional` presence flags and the `numbersequence` selector pack eight to a byte through a rolling sentinel, without `buffer.writebits`. Packed bytes stay Lua numbers while batching and are written into one exact-size buffer at send time.
- **Reliable bins pack bits across fires; unreliable bins do not.** On a reliable bin the sentinel runs continuously through the whole batch and the last partial byte is packed once, in `dispatch.sendBin`, so twenty frames carrying one boolean each cost 3 bytes rather than 20. Unreliable bins flush per fire, because chunk splits slice the boolean buffer by byte index and so must land on a byte boundary; streamed fires force a boundary for the same reason. The reader mirrors this with a `resetBools` flag on `dispatch.processBatch`, true only for unreliable batches.
- **Codec context.** Every read/write receives the active bin state: `refs`, `refCount`, `bools`, `amount` and `value`. `amount` counts completed boolean bytes, `value` is the rolling sentinel holding the partial byte and its bit count. `Bin.flushBools` packs the sentinel into `bools[]` and empties it. Because a reliable sentinel may hold bits from earlier frames, `Bin.tryWrite` captures it on entry and restores it on retry. Outgoing state is reused per bin; incoming batches own independent state, so yielding handlers cannot interfere.
- **Sizing.** Fixed-size schemas carry `size`, variable ones carry `sizeOf`. Schemas whose `sizeOf` has to walk the payload (map, `auto`, arrays of variable elements, anything containing them) are flagged `_costly` and write optimistically through `Bin.tryWrite`, growing and retrying, instead of being sized first.
- **Length prefixes.** Shared varint helpers at the top of `codec`, used by string, buffer, array and `auto`; call sites inline the one-byte case. Map counts are backfilled after the entries, so they use a padded two-byte varint.
- **Hybrid encodings.** `numbersequence` spends one boolean-channel bit choosing between a compact form (Time u16/65535, Value and Envelope u8/255, 4 bytes a keypoint) and a full form (three f32, 12 bytes). Compact requires every Value and Envelope in 0..1 and strictly increasing quantised times, since `NumberSequence.new` rejects duplicates. The write fetches `v.Keypoints` once and decides while writing, because that property rebuilds a Lua table on every access.
- **`compress` internals.** The compressed flag is the low bit of the length prefix rather than a boolean-channel bit, because it is only known after the inner value is written and the reader needs it before decoding. Booleans, optionals and refs inside the wrapped type still ride the real side channels, so only main-buffer bytes are compressed. `sizeOf` returns an upper bound, and the type is `_costly`. A wrapped tuple keeps its arity but loses the spread fast path.

## Gotchas

- **Registration order must match on both sides.** IDs are positional, so a divergence misroutes silently with no error. Keep every definition in one shared module that both sides require, the same one that initializes BitNet (`ReplicatedStorage.Networking` in this place).
- **Interned enums must be compiled from the same symbol set on both sides.** Index N means the Nth lexicographically sorted symbol *on that machine*, so a mismatch decodes a different symbol with no error. Keep the source table in ReplicatedStorage, literal and not built conditionally. Each compiled enum exposes `_fingerprint` (FNV-1a over the sorted set) for hand comparison, at no wire cost.
- **`array` cannot hold nils.** `#value` on a table with holes is undefined, so `array(optional(x))` silently truncates. Use a struct or a sentinel value instead.
- **`udim`, `udim2` and `vec*i16` wrap silently out of range**, since `writei16` does not complain. `check` is what catches it, so keep `ValidateOutgoing` on or bound the values yourself.
- **`compress` costs a flat ~25 microseconds per decompress regardless of size, paid per fire rather than per batch**, against 50-1000 ns to decode a whole frame. Wrap large redundant payloads only, never scalars. Narrowing the types first is usually the bigger win and the two stack.
- **Every type stays inside the size it declares**, `f24` included. It routes the f32 through a module-level scratch buffer instead of writing in place and sliding the bytes down; both measure the same, but the in-place form ran one byte past the field and forced every buffer sized from `size`/`sizeOf` to know about it. `bin.SLACK` and the spare byte in `compress` are kept as a margin now, not a requirement. `Bin.reserve` still copies the whole old buffer, slack included, so anything living there survives a grow — copying only `size` bytes once silently zeroed a real payload byte.
- **`types.auto` picks default encodings.** It covers nil, bool, number, string, vec2/3, color3, cframe, buffer, Instance (via ref), BrickColor, NumberRange, UDim, UDim2, NumberSequence, ColorSequence, array, map and `table.pack`-shaped tuples, holes included (one that is mostly holes goes as a map, which keeps every key); functions and threads error. A CFrame inside `auto` is the 18-byte `cframe`, a uuid is just a string and a Player is a ref, so name the type to get the narrow form.
- **`ValidateOutgoing` defaults on in Studio, off in production** (`constants.VALIDATE_OUTGOING_TYPES`).
- **Outgoing and incoming validation are different things.** `ValidateOutgoing` (`VALIDATE_OUTGOING_TYPES`) checks what you send; `VALIDATE_INCOMING_TYPES` checks what you receive, and only it runs in production.
- **Every rejection warns**, so a hostile client can fill the output. Act on `OnRejected` (count, then kick) rather than reading the log.

## Config

Keys the init config accepts, with their defaults from `constants`.

| Name                    | Default | Purpose                                          |
| ----------------------- | ------- | ------------------------------------------------ |
| `MAX_UNRELIABLE_BYTES`  | 1,000   | Combined main + boolean + ref unreliable chunk cap. |
| `UNRELIABLE_REF_BYTES`  | 8       | Assumed wire cost of one ref, for that cap.      |
| `DEFAULT_FUNC_TIMEOUT`  | 7       | Default `Timeout` for funcs.                     |
| `MAX_PENDING_PER_PLAYER`| 32      | Outstanding `:InvokeClient` calls allowed per player. |
| `VALIDATE_OUTGOING_TYPES` | IS_STUDIO | Default `ValidateOutgoing` for events and funcs. |
| `DEFAULT_BIN_SIZE`      | 256     | Starting bin buffer size in bytes.               |
| `BIN_GROWTH_FACTOR`     | 2       | Buffer grow multiplier on overflow.              |
| `VALIDATE_INCOMING_TYPES` | IS_SERVER | Decode incoming frames strictly and reject malformed ones. |
| `VALIDATE_DEFAULT_REJECT_NON_FINITE` | true | Reject NaN and ±inf floats; endpoints override with `ValidateAcceptNonFinite`. |
| `VALIDATE_MAX_DECOMPRESSED_BYTES` | 1,048,576 | What `compress` fields may inflate to across one incoming batch. |
| `PLAYER_ID_ATTRIBUTE`   | "BitNetId" | Attribute carrying each player's u8 id for `types.player`. Must match on both sides. |
]]
return {}