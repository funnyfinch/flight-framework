--overview:
--v1.0.0
--[[description:

]]
--!strict


--// service
local replicatedStorage = game:GetService("ReplicatedStorage")


--// modules
local modules = replicatedStorage.modules
local newSignal = require(modules.signal)


--// types
type cleanupMethod<T = any> = (T) -> () | true

export type cleaner = {
	give: <T>(self: cleaner, source: T, cleanupMethod: (string | (T) -> ())?) -> T,
	scope: (self: cleaner) -> cleaner,
	cleanup: (self: cleaner) -> (),
	destroy: (self: cleaner) -> (),
}


--// helper
local validMethods = {"Destroy", "Disconnect", "destroy", "disconnect"}

local function getCleanupMethod<T>(resource: T, cleanupMethod: ((T) -> () | string)?): cleanupMethod<T>
	local t = typeof(resource)
	if t == "function" then
		return true
	else
		if type(cleanupMethod) == "string" then
			local ok, result = pcall(function()
				local method = (resource :: any)[cleanupMethod]
			end)
			if ok and result then
				return result :: any
			end
		end
		
		for _, method in validMethods do
			local ok, result = pcall(function()
				return (resource :: any)[method]
			end)
			if ok and result then
				return result
			end
		end
	end
	
	error(`Could not find cleanupMethod for [{resource}] of type <{typeof(resource)}>`)
end



local function newCleaner(): cleaner
	local cleaner = {} :: cleaner
	
	local i = 0
	local resources = {} :: { [any | () -> ()]: cleanupMethod }
	
	function cleaner:give(resource, cleanupMethod)
		if resource == nil then
			error("resource is nil")
		end
		
		local method: cleanupMethod = getCleanupMethod(resource, cleanupMethod)
		if not method then
			--error(`Could not find cleanupMethod for [{resource}] of type <{typeof(resource)}>`)
			error(resource)
		end
		resources[resource] = method
		
		--return function()
		--	resources[resource] = nil
		--end
		return resource
	end
	
	function cleaner:scope()
		local child = newCleaner()
		cleaner:give(child)
		return child
	end
	
	function cleaner:cleanup()
		for resource, method: cleanupMethod in resources do
			local ok, err = pcall(function()
				if method == true then
					(resource :: () -> ())()
					return
				end
				(method :: any)(resource)
			end)
			if not ok then
				warn(`Issue cleaning up [{resource}]: {err}`)
			end
			resources[resource] = nil
		end
	end
	
	function cleaner:destroy()
		cleaner:cleanup()
		table.clear(cleaner)
		setmetatable(cleaner, nil)
	end
	
	return cleaner
end


--// return
return {
	new = newCleaner
}