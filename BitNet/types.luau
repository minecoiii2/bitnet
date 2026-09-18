-- just a types module

const signal = require(script.Parent.instances.signal)

type Tuple<T...> = (T...) -> ()
--type Tuple<T...> = () -> (T...)

export type BitnetTypes = {
	u8: number,
	u16: number,
	u24: number,
	u32: number,
	i8: number,
	i16: number,
	i24: number,
	i32: number,
	f24: number,
	f32: number,
	f64: number,

	bool: boolean,
	string: string,
	uuid: string,
	nothing: nil,
	ref: unknown,
	unknown: unknown,
	instance: (...string) -> Instance,
	player: Player,
	number: number,

	buffer: buffer,
	vec2: Vector2,
	vec3: Vector3,
	color3: Color3,
	cframe: CFrame,
	cframelong: CFrame,
	brickcolor: BrickColor,
	numberrange: NumberRange,
	udim: UDim,
	udim2: UDim2,
	numbersequence: NumberSequence,
	colorsequence: ColorSequence,
	auto: any,

	struct: <T>(format: T) -> T,
	array: <T>(value: T) -> { [number]: T },
	optional: <T>(value: T) -> T?,
	map: <K, V>(key: K, value: V) -> { [K]: V },
	enum: (enumType: Enum) -> EnumItem,
	enumFromKeys: <T>(source: T) -> keyof<T>,
	enumFromValues: (source: { [any]: string }) -> string,
	tuple: <T...>(T...) -> Tuple<T...>,
	vec3i16: (scale: number?) -> Vector3,
	vec2i16: (scale: number?) -> Vector2,
	compress: <T>(value: T, level: number?) -> T,
}

type Connection = {
	Connected: boolean,
	Disconnect: (self: Connection) -> (),
}

export type ServerEventSignal<A...> = {
	Connect: (self: ServerEventSignal<A...>, callback: (Player, A...) -> ()) -> Connection,
	Once: (self: ServerEventSignal<A...>, callback: (Player, A...) -> ()) -> Connection,
	Wait: (self: ServerEventSignal<A...>) -> (Player, A...),
	DisconnectAll: (self: ServerEventSignal<A...>) -> (),
	Destroy: (self: ServerEventSignal<A...>) -> (),
}
export type ClientEventSignal<A...> = {
	Connect: (self: ClientEventSignal<A...>, callback: (A...) -> ()) -> Connection,
	Once: (self: ClientEventSignal<A...>, callback: (A...) -> ()) -> Connection,
	Wait: (self: ClientEventSignal<A...>) -> (A...),
	DisconnectAll: (self: ClientEventSignal<A...>) -> (),
	Destroy: (self: ClientEventSignal<A...>) -> (),
}

export type ServerEvent<A...> = {
	FireServer: (self: ServerEvent<A...>, A...) -> (),
	FireClient: (self: ServerEvent<A...>, player: Player, A...) -> (),
	FireClientsStreamed: (self: ServerEvent<A...>, at: Vector3, range: number, A...) -> (),
	FireClientsStreamedWithExclusion: (self: ServerEvent<A...>, at: Vector3, range: number, exclude: Player, A...) -> (),
	FireAllClients: (self: ServerEvent<A...>, A...) -> (),
	OnServerEvent: ServerEventSignal<A...>,
	OnClientEvent: ClientEventSignal<A...>,
}

export type ServerFunction<A..., R...> = {
	InvokeServer: (self: ServerFunction<A..., R...>, A...) -> R...,
	InvokeClient: (self: ServerFunction<A..., R...>, player: Player, A...) -> R...,
	SetCallback: (self: ServerFunction<A..., R...>, callback: (Player, A...) -> R...) -> (),
	SetServerCallback: (self: ServerFunction<A..., R...>, callback: (Player, A...) -> R...) -> (),
	SetClientCallback: (self: ServerFunction<A..., R...>, callback: (A...) -> R...) -> (),
}

export type Config = {
	DEFAULT_FUNC_TIMEOUT: number?,
	MAX_PENDING_PER_PLAYER: number?,

	VALIDATE_OUTGOING_TYPES: boolean?,
	VALIDATE_INCOMING_TYPES: boolean?,
	VALIDATE_DEFAULT_REJECT_NON_FINITE: boolean?,
	VALIDATE_MAX_DECOMPRESSED_BYTES: number?,

	MAX_UNRELIABLE_BYTES: number?,
	UNRELIABLE_REF_BYTES: number?,
	PLAYER_ID_ATTRIBUTE: string?,
	DEFAULT_BIN_SIZE: number?,
	BIN_GROWTH_FACTOR: number?,
}

export type Bitnet = {
	types: BitnetTypes,
	
	event: <A...>(config: {
		Args: (A...) -> (), 
		Reliable: boolean?, 
		ValidateOutgoing: boolean?,
		RateLimit: { calls: number, per: number }?,
		ValidateAcceptNonFinite: boolean?,
	}) -> ServerEvent<A...>,
	
	func: <A..., R...>(config: {
		Args: (A...) -> (),
		Returns: (R...) -> (),
		Timeout: number?,
		ValidateOutgoing: boolean?,
		RateLimit: { calls: number, per: number }?,
		ValidateAcceptNonFinite: boolean?,
	}) -> ServerFunction<A..., R...>,

	signal: <T...>() -> signal.Signal<T...>,
	
	-- signals
	
	OnRejected: signal.Signal<Player?, number?, string>,
}

return nil