--!native
--!optimize 2

const ReplicatedStorage = game:GetService("ReplicatedStorage")
const RunService = game:GetService("RunService")
const IS_SERVER = RunService:IsServer()

const constants = require(script.Parent.Parent.constants)

const function getOrCreate(name: string, className: string): RemoteEvent
	const existing = script:FindFirstChild(name)
	if existing then
		if existing.ClassName == className then
			return existing :: RemoteEvent
		elseif IS_SERVER then
			existing:Destroy()
		else
			warn(`bitnet: {name} exists with wrong class {existing.ClassName} (expected {className})`)
			return existing :: RemoteEvent
		end
	end
	if IS_SERVER then
		const re = Instance.new(className)
		re.Name = name
		re.Parent = script
		return re :: RemoteEvent
	else
		return script:WaitForChild(name) :: RemoteEvent
	end
end

return {
	reliable = getOrCreate("BitnetReliable", "RemoteEvent"),
	unreliable = getOrCreate("BitnetUnreliable", "UnreliableRemoteEvent"),
	MAX_UNRELIABLE_BYTES = constants.MAX_UNRELIABLE_BYTES,
}