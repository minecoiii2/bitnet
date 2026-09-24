const RunService = game:GetService('RunService')
const IS_STUDIO = RunService:IsStudio()
const IS_SERVER = RunService:IsServer()

return {
	DEFAULT_FUNC_TIMEOUT = 7, -- client remote function timeout
	MAX_PENDING_PER_PLAYER = 32, -- max invokes the server sent a player that await an answer
	MAX_CALLBACKS_PER_PLAYER = 32, -- max invokes a player sent the server that are still running

	DEBUG = false, -- default Debug for every event and func; also creates BitNet.EventSent and EventReceived

	VALIDATE_OUTGOING_TYPES = true and IS_STUDIO, -- check values against their schema before sending
	VALIDATE_INCOMING_TYPES = IS_SERVER, -- decode incoming frames strictly and reject malformed ones
	VALIDATE_DEFAULT_REJECT_NON_FINITE = true, -- reject NaN and inf
	VALIDATE_MAX_DECOMPRESSED_BYTES = 1048576, -- 1MB

	MAX_UNRELIABLE_BYTES = 1000, -- unreliable cap
	UNRELIABLE_REF_BYTES = 8, -- assumed wire cost of one ref, counted against the cap above
	PLAYER_ID_ATTRIBUTE = "BitNetId",
	DEFAULT_BIN_SIZE = 256, -- starting buffer size
	BIN_GROWTH_FACTOR = 2, -- size multiplier on overflow
}