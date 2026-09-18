# BitNet

Buffer-based networking library for Roblox. Replaces RemoteEvents and RemoteFunctions with typed, batched events and funcs that all run over two shared remotes.

- Every fire in a frame is packed into one buffer per player and sent once per Heartbeat
- Schemas describe the payload, so data goes out as tightly packed bytes instead of Lua tables
- Booleans cost one bit, Instances cost no buffer space
- Reliable and unreliable events, two-way funcs, rate limiting and runtime typechecking

## Installation

BitNet comes with **Networking**, a template module where you define all of your events and funcs.

**Manual:** download `BitNet.rbxm` and `Networking.rbxm` from [Releases](https://github.com/minecoiii2/bitnet/releases) and insert both into `ReplicatedStorage`.

**Wally**
```toml
[dependencies]
BitNet = "minecoiii2/bitnet@3.0.0"
```
Then copy [`Networking.luau`](Networking.luau) into your project and change its require to point at your packages folder, e.g. `ReplicatedStorage.Packages.BitNet`.

## Quick start

Every event and func goes in the table that `Networking` returns. The server and client both require this one module, so everything registers in the same order on both sides.

```lua
-- ReplicatedStorage.Networking
return {
	Chat = RemoteEvent({
		Args = args(string, u8),
	}),
	Hit = RemoteEvent({
		Args = struct({ target = Instance, damage = u16 }),
		Reliable = false,
		RateLimit = BuildRatelimit(20, 1),
	}),
	GetPrice = RemoteFunction({
		Args = string,
		Returns = u32,
	}),
}
```

The template sets up short names for everything at the top: `RemoteEvent` is `BitNet.event`, `RemoteFunction` is `BitNet.func`, `args` is `tuple`, and the types are named after their Roblox equivalents (`Vector3`, `CFrame`, `Instance`, ...). Two names differ from the table below: `any` is `ref`, and `auto` is BitNet's `any`.

```lua
-- Server
const Networking = require(ReplicatedStorage.Networking)

Networking.Chat.OnServerEvent:Connect(function(player, message, channel)
	Networking.Chat:FireAllClients(message, channel)
end)

Networking.GetPrice:SetCallback(function(player, itemId)
	return 100
end)
```

```lua
-- Client
const Networking = require(ReplicatedStorage.Networking)

Networking.Chat.OnClientEvent:Connect(function(message, channel)
	print(message)
end)

Networking.Chat:FireServer("hello", 1)
const price = Networking.GetPrice:InvokeServer("sword")
```

## Types

| Type | Bytes | Notes |
| ---- | ----- | ----- |
| `u8` `u16` `u24` `u32` | 1–4 | Unsigned integers |
| `i8` `i16` `i24` `i32` | 1–4 | Signed integers |
| `f24` `f32` `f64` | 3, 4, 8 | `number` is `f64`. `f24` is lossy (~3e-5 relative error) |
| `bool` | 1 bit | Packed eight to a byte |
| `string` `buffer` | 1–5 + length | |
| `uuid` | 16 | Canonical 36-character lowercase form |
| `vec2` `vec3` | 8, 12 | |
| `vec2i16(scale?)` `vec3i16(scale?)` | 4, 6 | Fixed point, ±327 studs at the default scale of 100 |
| `cframe` `cframelong` | 18, 24 | `cframe` uses 16-bit rotation angles |
| `color3` | 3 | 8 bits per channel |
| `brickcolor` `numberrange` `udim` `udim2` | 2, 8, 4, 8 | |
| `numbersequence` `colorsequence` | varies | |
| `instance` `ref` `unknown` | 0 | Sent next to the buffer as normal Roblox values |
| `any` | 1 + value | Picks an encoding at runtime |
| `nothing` | 0 | Always nil |

The narrow types (`u24`, `i24`, `f24`, `vec*i16`, `cframe`) save bytes but cost a bit of CPU. Use them when bandwidth matters.

**Combinators**
- `struct(format)`: table with fixed keys
- `array(value)`: array of one type
- `map(key, value)`: dictionary, up to 16,383 entries
- `optional(value)`: value or nil
- `tuple(...)`: multiple arguments
- `enum(Enum.X)`: a Roblox EnumItem
- `enumFromKeys(t)` / `enumFromValues(t)`: string from a known set, sent as an index
- `compress(value, level?)`: Zstd-compresses the value when that makes it smaller

## Events

`bitnet.event(options)`

| Option | Default | Description |
| ------ | ------- | ----------- |
| `Args` | required | Payload type |
| `Reliable` | `true` | Use the reliable or unreliable channel |
| `Typecheck` | Studio only | Validate payloads before sending |
| `RateLimit` | none | `{ calls, per }` limit on fires from each client |

**Methods:** `:FireServer(...)`, `:FireClient(player, ...)`, `:FireAllClients(...)`, `:FireClientsStreamed(position, range, ...)`, `:FireClientsStreamedWithExclusion(position, range, player, ...)`

**Listening:** `.OnServerEvent` gives `(player, ...)` and `.OnClientEvent` gives `(...)`. `.OnReceived` is the same signal under another name.

On the client, fires that arrive before anything is connected are queued and delivered to the first listener.

## Funcs

`bitnet.func(options)`

| Option | Default | Description |
| ------ | ------- | ----------- |
| `Args` | required | Request type |
| `Returns` | required | Response type |
| `Timeout` | `7` | Seconds before the invoke errors. `0` or `math.huge` waits forever |
| `Typecheck` | Studio only | Validate payloads before sending |
| `RateLimit` | none | `{ calls, per }` limit on invokes from each client |

**Methods:** `:InvokeServer(...)`, `:InvokeClient(player, ...)`, `:SetCallback(fn)`, plus `:SetServerCallback(fn)` and `:SetClientCallback(fn)`, which error when called on the wrong side.

Funcs work in both directions and are always reliable. Invoking a client has some safety rules built in:
- `:InvokeClient` requires a finite `Timeout`
- A player can have at most 32 pending invokes
- Only the invoked player can answer, and pending invokes fail as soon as that player leaves

## Signal

`bitnet.signal()` creates a local signal that isn't networked. It has `:Fire`, `:Connect`, `:Once`, `:Wait`, `:DisconnectAll` and `:Destroy`. Connections have `:Disconnect`, `:Reconnect` and `:Destroy`.

## Gotchas

- **Register in the same order on both sides.** IDs are assigned in registration order, and a mismatch sends data to the wrong handler without any error. Define everything in `Networking` and require it before anything fires.
- **`enumFromKeys` and `enumFromValues` need the same set on both sides.** Keep the source table in ReplicatedStorage, written out literally.
- **`array` can't hold nil.** `array(optional(x))` gets cut off at the first nil.
- **`udim`, `udim2` and `vec*i16` wrap around when out of range.** Only `Typecheck` catches it.
- **Unreliable fires over 1,000 bytes are dropped** with a warning.
- **`compress` costs about 25µs per fire to decompress.** Only use it on large, repetitive payloads.
- **`any` picks default encodings**, so a CFrame inside `any` is sent as `cframe`. Name the type yourself when you need a specific one.
- **`Typecheck` is on in Studio and off in live servers** unless you set it.

## License

MIT
