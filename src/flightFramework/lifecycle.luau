--[[description:

]]
--!strict


--// services
local replicatedStorage = game:GetService("ReplicatedStorage")
local runService = game:GetService("RunService")


--// modules
local modules = replicatedStorage.modules
local network = require(modules.network)
local signal = require(modules.signal)


--// types
--imported
type signal<P... = ()> = signal.signal<P...>

--native
export type node = {
	module: ModuleScript,
	dependencies: { node },
	dependents: { node }
}

export type loader = {
	finished: signal,
	order: { node },
	build: (self: loader, root: Instance, onLoad: (ModuleScript) -> ()?) -> (),
	load: (self: loader, instance: Instance) -> node?,
	moduleCount: number,
}


--// root
local loader = {
	finished = signal.new( { sticky = "latest" } :: signal.signalConfig )
} :: loader


--// helpers

local function moduleFromFullName(name: string): Instance?
	local current = game
	for _, key in name:split(".") do
		current = current:FindFirstChild(key)
	end
	return current
end

local built = false
function loader:build(root: Instance, onLoad)
	assert(not built, "Can only build lifecycle once")
	built = true
	
	-- networking / waiting
	local finished = false

	local id = network.id("lifecycleFinished")
	local finishedQuery = network.query<<nil, nil>>(id, nil, nil)
	network.reliable:attach(finishedQuery)

	if runService:IsServer() then
		finishedQuery.respond = function()
			if not finished then
				repeat task.wait() until finished
			end
			return nil
		end
	elseif runService:IsClient() then
		finishedQuery:request().received:wait()
	end
	
	local rootNodes = {} :: { node }
	local nodeList = {} :: { [Instance]: node }

	local function newNode(module: ModuleScript): node
		local node: node = {
			module = module,
			dependencies = {},
			dependents = {}
		}
		nodeList[module] = node
		return node
	end

	local function node(dependencies: { ModuleScript })
		local fullName = debug.info(coroutine.running(), 2, "s")
		local caller = moduleFromFullName(fullName) :: ModuleScript?
		assert(caller, `Could not get module from [{fullName}]`)

		local node = newNode(caller)
		for _, dependency in dependencies do
			local dependencyNode = loader:load(dependency)
			assert(dependencyNode, `Could not get node for dependency of [{caller.Name}], [{dependency.Name}]`)
			table.insert(node.dependencies, dependencyNode)
			table.insert(dependencyNode.dependents, node)
		end
	end
	
	-- set up load function
	local traversed = {} :: { [Instance]: true }
	function loader:load(instance: Instance)
		if typeof(instance) ~= "Instance" or instance:GetAttribute("block") then
			error(`Could not load [{instance.Name}] of type <{typeof(instance)}>`)
		end

		if traversed[instance] then
			return nodeList[instance]
		end
		traversed[instance] = true

		if not instance:GetAttribute("ignore") and instance:IsA("ModuleScript") then
			if onLoad then
				onLoad(instance)
			end

			local ok, err = pcall(require, instance)
			if not ok then
				warn(`Issue loading [{instance.Name}]: {err}`)
			end

			local node = nodeList[instance] or newNode(instance :: ModuleScript)
			return node
		end
	
		return nil
	end
	
	-- get valid modules
	local validModules = {} :: { ModuleScript }
	for _, module: ModuleScript in root:QueryDescendants("ModuleScript:not([$ignore]):not([$block])") do
		local current = module
		local valid = true
		while current do
			if current:GetAttribute("block") then
				valid = false
				break
			end
			current = current.Parent
		end
		if valid then
			table.insert(validModules, module)
		end
	end
	
	loader.moduleCount = #validModules
	
	-- load modules
	for _, module in validModules do
		loader:load(module)
	end

	-- establish root nodes
	for module, node in nodeList do
		if #node.dependencies == 0 then
			table.insert(rootNodes, node)
		end
	end

	-- topological sort
	local order = {}

	local remaining = {} :: { [node]: number }
	local ready = {} :: { node }

	for _, node in nodeList do
		local count = #node.dependencies
		remaining[node] = count

		if count == 0 then
			table.insert(ready, node)
		end
	end

	local index = 1
	while index <= #ready do
		local current = ready[index]
		index += 1

		table.insert(order, current)

		for _, dependent in current.dependents do
			remaining[dependent] -= 1

			if remaining[dependent] == 0 then
				table.insert(ready, dependent)
			end
		end
	end

	loader.order = order
	finished = true
	loader.finished:fire()
end

if runService:IsServer() then
	game:BindToClose(function()
		--signal.wrap(game:GetService("Players")):disconnectAll()
	end)
end


--// return
return loader
