# BitNet

Lightning-fast, buffer-based networking library for Roblox.

BitNet replaces your RemoteEvents and RemoteFunctions with events and functions that you define in a single shared `Networking` module. They work like the Roblox ones you already know (`FireServer`, `OnServerEvent`, `InvokeServer`...), except each one is locked to a **schema**: a description of exactly what it sends.

```lua
Hit = RemoteEvent({
	Args = args(struct({ target = player, damage = u16, critical = bool })),
})
```

Because the server and client both know that schema, only the values go over the network. The keys and type information are never sent. This `Hit` fire costs 3 bytes and 1 bit, plus a 1-byte event id.

## Why BitNet

- **Smaller packets.** Values are written into a buffer at the exact size you choose: a `u8` is 1 byte, a `bool` is 1 bit
- **Speed.** Encoding and decoding are among the fastest out there (see [Benchmark](#benchmark))
- **Exploit-resistant by default.** The server strictly decodes everything clients send. Malformed or out-of-bounds data is rejected before it reaches your handlers, and `OnRejected` tells you who sent it.
- **Typed in Luau.** Types come straight from the schema, so `FireServer` arguments and `OnServerEvent` parameters are type-checked in your editor with no extra steps.
- **Built-in extras.** Rate limiting, unreliable events, type-validation, sending only to nearby players, Zstd compression and more.

## Benchmark

**BitNet offers the best balance of speed and payload size:** only 2 bytes behind *Lync* payloads, while running up to 2.4x faster.

- Primitive: A single u8
- Medium: Struct containing integers, strings and an array
- Complex: Struct containing integers, strings, nested structs, nested arrays

| Module | Round trip: primitive / medium / complex | Payload: primitive / medium / complex |
|---|---:|---:|
| **BitNet** | 272 / **781** / **1,542 ns** | 1 / 36 / 79 B |
| Packet | 413 / 978 / 2,797 ns | 1 / 37 / 81 B |
| Lync | 211 / 1,119 / 3,659 ns | **1 / 34 / 77 B** |
| Jolt | 356 / 1,109 / 3,797 ns | 2 / 64 / 230 B |
| ByteNet | **178** / 2,332 / 7,162 ns | 1 / 41 / 83 B |
| NetRay | 1,067 / 4,462 / 18,907 ns | 2 / 67 / 306 B |
| BridgeNet2 | — | 9 / 89 / 468 B |

## Installation

BitNet comes with a **Networking** template module. It already has every BitNet type, function and helper set up, ready for your remotes.

**Manual:** download `BitNet.rbxm` and `Networking.rbxm` from [Releases](https://github.com/minecoiii2/bitnet/releases) and insert both into `ReplicatedStorage`.

**Wally**
```toml
[dependencies]
BitNet = "minecoiii2/bitnet@3.2.0"
```
Then copy [`Networking.luau`](Networking.luau) into your project and change its require to point at your packages folder, e.g. `ReplicatedStorage.Packages.BitNet`.

## Quick start

Every event and function goes in the table that `Networking` returns. The server and client both require this one module, so everything registers in the same order on both sides.

```lua
-- ReplicatedStorage.Networking
const BitNet = require(ReplicatedStorage.BitNet)({})
...

local Islands = enumFromKeys(ReplicatedStorage.IslandDictionary)

return {
	Chat = {
		Send = RemoteEvent({
			Args = args(string, u16),
		}),
		Receive = RemoteEvent({
			Args = args(player, string, u16),
		}),

		GetAllChats = RemoteFunction({
			Args = args(nothing),
			Returns = args(
				compress(array(
					struct({
						Sender = player,
						At = u32,
						Message = string,
						WasFiltered = bool,
					})
				))
			)
		}),
	},

	TeleportToIsland = RemoteEvent({
		Args = args(Islands, uuid, u32),
	}),
}
```

```lua
-- Server
const Networking = require(ReplicatedStorage.Networking)

Networking.Chat.Send.OnServerEvent:Connect(function(player, message, channel)
	Networking.Chat.Receive:FireAllClients(player, message, channel)
end)

Networking.Chat.GetAllChats:SetServerCallback(function(player)
	return AllReceivedChats
end)
```

```lua
-- Client
const Networking = require(ReplicatedStorage.Networking)

Networking.Chat.Receive.OnClientEvent:Connect(function(player, message, channel)
	print(message, 'sent by', player, 'in channel', channel)
end)

Networking.Chat.Send:FireServer("hello", 1)
```

## Types

| Type | Bytes | Notes |
| ---- | ----- | ----- |
| `u8` `u16` `u24` `u32` | 1–4 | Unsigned integers |
| `i8` `i16` `i24` `i32` | 1–4 | Signed integers |
| `f24` `f32` `f64` | 3, 4, 8 | `number` is `f64` |
| `bool` | 1 bit | Packed |
| `string` `buffer` | 1–5 + length | |
| `uuid` | 16 | Canonical 36-character lowercase form |
| `vec2` `vec3` | 8, 12 | |
| `vec2i16(scale?)` `vec3i16(scale?)` | 4, 6 | Fixed point, ±327 studs at the default scale of 100 |
| `cframe` `cframelong` | 18, 24 | `cframe` is lossy while `cframelong` isn't |
| `color3` | 3 | 8 bits per channel |
| `brickcolor` `numberrange` `udim` `udim2` | 2, 8, 4, 8 | |
| `numbersequence` `colorsequence` | varies | |
| `player` | 1 | Sent as u8. A player who left more than 5 seconds ago arrives as nil |
| `ref` `unknown` | 0 | Sent next to the buffer as normal Roblox values |
| `auto` | 1 + value | Picks an encoding at runtime |
| `nothing` | 0 | Always nil |

The narrow types (`u24`, `i24`, `f24`, `vec*i16`, `cframe`) save bytes but cost a bit of CPU. In the Networking template, `any` is `ref`.

**Combinators**
- `struct(format)`: table with fixed keys
- `array(value)`: array of one type
- `map(key, value)`: dictionary (up to 16,383 entries)
- `optional(value)`: value or nil
- `instance(...className)`: an Instance. `instance()` accepts any class, `instance("BasePart", "Model")` only those. Always call it, even with no classes
- `tuple(...)`: multiple arguments
- `enum(Enum.X)`: a Roblox EnumItem
- `enumFromKeys(t)` / `enumFromValues(t)`: string from a known set, sent as an index
- `compress(value, level?)`: Zstd-compresses the value when that makes it smaller

## Events

`RemoteEvent(options)` in the template, `BitNet.event(options)` without it.

| Option | Default | Description |
| ------ | ------- | ----------- |
| `Args` | required | Payload schema |
| `Reliable` | `true` | Use the reliable or unreliable channel |
| `RateLimit` | `nil` | `{ calls, per }` limit on fires per client |
| `ValidateOutgoing` | Studio only | Check values against the schema before sending |
| `ValidateAcceptNonFinite` | `false` | Let NaN and inf through incoming validation |

**Methods:**
- `:FireServer(...)`
- `:FireClient(player, ...)`
- `:FireAllClients(...)`
- `:FireClientsStreamed(position, range, ...)`: Send to players within range
- `:FireClientsStreamedWithExclusion(position, range, player, ...)`: Same, excluding one player

**Listening:**
- `.OnServerEvent` gives `(player, ...)`
- `.OnClientEvent` gives `(...)`

On the client, fires that arrive before anything is connected are queued (up to 256) and delivered once something connects.

## Funcs

`RemoteFunction(options)` in the template, `BitNet.func(options)` without it.

| Option | Default | Description |
| ------ | ------- | ----------- |
| `Args` | required | Request schema |
| `Returns` | required | Response schema |
| `Timeout` | `7` | Yield timeout. `0` or `math.huge` waits forever |
| `RateLimit` | `nil` | `{ calls, per }` limit on invokes per client |
| `ValidateOutgoing` | Studio only | Check values against the schema before sending |
| `ValidateAcceptNonFinite` | `false` | Let NaN and inf through incoming validation |

**Methods:**
- `:InvokeServer(...)`
- `:InvokeClient(player, ...)`
- `:SetServerCallback(fn)`
- `:SetClientCallback(fn)`

If the other side can't answer (its callback errors, it has no callback, or `RateLimit` refused the call), the invoke errors right away with the reason instead of waiting for `Timeout`.

## Configuration

`require(BitNet)` returns a function that starts BitNet. Call it once, at the top of `Networking`, with a table of overrides, or `{}` to keep the defaults:

```lua
-- ReplicatedStorage.Networking
const BitNet = require(ReplicatedStorage.BitNet)({
	DEFAULT_FUNC_TIMEOUT = 10,
	VALIDATE_OUTGOING_TYPES = true,
})
```

Other scripts get the same BitNet by calling it with no config: `require(ReplicatedStorage.BitNet)()`. Require `Networking` before doing that, otherwise BitNet starts with the defaults and `Networking`'s own call errors.

| Constant | Default | Description |
| -------- | ------- | ----------- |
| `DEFAULT_FUNC_TIMEOUT` | `7` | Seconds a RemoteFunction waits for a response. Overridden per function by `Timeout` |
| `VALIDATE_OUTGOING_TYPES` | Studio only | Check values against their schema before sending. Overridden per endpoint by `ValidateOutgoing` |
| `VALIDATE_INCOMING_TYPES` | Server only | Strictly decode incoming data and reject malformed / malicious frames |
| `VALIDATE_DEFAULT_REJECT_NON_FINITE` | `true` | Reject NaN and inf in incoming data. Overridden per endpoint by `ValidateAcceptNonFinite` |

Every other value in BitNet's `constants` module can be overridden the same way.

## Important Notes

- **Reliable and unreliable events aren't ordered relative to each other.** If a reliable event is fired after an unreliable one, either one can be received first.
- **`:FireAllClients` and `:FireClient` are batched separately.** Within a frame, order is only kept between fires sent the same way, so a `:FireAllClients` can be received before a `:FireClient` that was called earlier. If two fires must arrive in order, send them the same way.

## Trivia

- BitNet was originally meant to be a ByteNet fork, but it ended up turning into a full rewrite.

## License

MIT
