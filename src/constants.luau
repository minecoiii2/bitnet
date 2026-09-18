const RunService = game:GetService('RunService')
const IS_STUDIO = RunService:IsStudio()
const readme = require(script.Parent.readme) -- so that AIs read it

return {
	MAX_UNRELIABLE_BYTES = 1000, -- unreliable cap
	UNRELIABLE_REF_BYTES = 8, -- assumed wire cost of one ref, counted against the cap above

	DEFAULT_FUNC_TIMEOUT = 7, -- client remote function timeout
	MAX_PENDING_PER_PLAYER = 32, -- outstanding ServerToClient invokes allowed per player
	DEFAULT_TYPECHECK = true and IS_STUDIO, -- runtime structural validation

	DEFAULT_BIN_SIZE = 256, -- starting buffer size
	BIN_GROWTH_FACTOR = 2, -- size multiplier on overflow
}