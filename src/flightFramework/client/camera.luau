--overview:
--v1.0.0
--[[description:

]]
--!strict


--// services
local replicatedStorage = game:GetService("ReplicatedStorage")


--// modules
local modules = replicatedStorage.modules
local cleaner = require(modules.cleaner)
local state = require(modules.state)


--// camera state
local camera = state.value(workspace.CurrentCamera :: Camera)
local viewportSize = state.value(camera:peek().ViewportSize)

local cleaner = cleaner.new()
local function hookCamera(camera: Camera)
	cleaner:cleanup()
	cleaner:give(camera:GetPropertyChangedSignal("ViewportSize"):Connect(function()
		viewportSize:set(camera.ViewportSize)
	end))
end

hookCamera(camera:peek())
camera.changed:connect(hookCamera)

workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(function()
	camera:set(workspace.CurrentCamera :: Camera)
end)


--// root
local cameraModule = {
	camera = camera,
	viewportSize = viewportSize,
}


--// return
return cameraModule