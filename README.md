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

- **Smaller packets.** Values are written into a buffer at the exact size you choose: a `u8` is 1 byte, a `bool` is 1 bit, an Instance takes no buffer space at all.
- **Fewer remote calls.** Every fire in a frame is batched into one send per player, over just two remotes (reliable and unreliable).
- **Exploit-resistant by default.** The server strictly decodes everything clients send. Malformed or out-of-bounds data is rejected before it reaches your handlers (and `OnRejected` tells you who sent it)
- **Typed in Luau.** Types come straight from the schema, so `FireServer` arguments and `OnServerEvent` parameters are type-checked in your editor with no extra steps.
- **Built-in extras.** Rate limiting, unreliable events, sending only to nearby players, Zstd compression and more

## Installation

BitNet comes with a **Networking** template module. It already has every BitNet type, function and helper set up, ready for your remotes.

**Manual:** download `BitNet.rbxm` and `Networking.rbxm` from [Releases](https://github.com/minecoiii2/bitnet/releases) and insert both into `ReplicatedStorage`.

**Wally**
```toml
[dependencies]
BitNet = "minecoiii2/bitnet@3.0.0"
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
| `player` | 1 | Sent as u8. A player who has left arrives as nil |
| `ref` `unknown` `any` | 0 | Sent next to the buffer as normal Roblox values |
| `auto` | 1 + value | Picks an encoding at runtime |
| `nothing` | 0 | Always nil |

The narrow types (`u24`, `i24`, `f24`, `vec*i16`, `cframe`) save bytes but cost a bit of CPU. In the Networking template, `any` is `ref`.

**Combinators**
- `struct(format)`: table with fixed keys
- `array(value)`: array of one type
- `map(key, value)`: dictionary (up to 16,383 entries)
- `optional(value)`: value or nil
- `instance(...className)`: optional multiple classNames
- `tuple(...)`: multiple arguments
- `enum(Enum.X)`: a Roblox EnumItem
- `enumFromKeys(t)` / `enumFromValues(t)`: string from a known set, sent as an index
- `compress(value, level?)`: Zstd-compresses the value when that makes it smaller

## Events

`bitnet.event(options)`

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

On the client, fires that arrive before anything is connected are queued and delivered to the first listener.

## Funcs

`bitnet.func(options)`

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

## Configuration

`require(BitNet)` returns a function that starts BitNet. Call it once, at the top of `Networking`, with a table of overrides, or `{}` to keep the defaults:

```lua
-- ReplicatedStorage.Networking
const BitNet = require(ReplicatedStorage.BitNet)({
	DEFAULT_FUNC_TIMEOUT = 10,
	VALIDATE_OUTGOING_TYPES = true,
})
```

| Constant | Default | Description |
| -------- | ------- | ----------- |
| `DEFAULT_FUNC_TIMEOUT` | `7` | Seconds a remoteFunction waits for a response. Overridden per function by `Timeout` |
| `VALIDATE_OUTGOING_TYPES` | Studio only | Check values against their schema before sending. Overridden per endpoint by `ValidateOutgoing` |
| `VALIDATE_INCOMING_TYPES` | Server only | Strictly decode incoming data and reject malformed frames |
| `VALIDATE_DEFAULT_REJECT_NON_FINITE` | `true` | Reject NaN and inf in incoming data. Overridden per endpoint by `ValidateAcceptNonFinite` |

Every other value in BitNet's `constants` module can be overridden the same way.

## License

MIT
