--7/24/2026
--[[ description:

	- lightweight signal module tailored for flightFramework
	
	- notes:
		- this module is slightly slower than alternatives
			- luausignal is on average 4x faster
			- signalplus is on average about 8% faster
		- immediate-mode dispatching can be dangerous in the event of errors or yielding
	
]]
--!strict


--// config
local config = require("./utils").config

local signalConfig = config.new {
	dispatchMethod = config.enum { immediate = 0, deferred = 1 } "immediate",
	sticky = config.optional(config.enum { latest = 0, all = 1, consume = 2 })(nil)
}
export type signalConfig = typeof(signalConfig.input)


local connectionConfig = config.new {
	dispatchMethod = config.optional(config.enum { immediate = 0, deferred = 1 })(nil),
	consumeQueue = config.boolean(true)
}
export type connectionConfig = typeof(connectionConfig.input)


--// types
export type signal<P... = ...any> = {
	connect: (self: signal<P...>, (P...) -> (), connectionConfig?) -> connection<P...>,
	once: (self: signal<P...>, (P...) -> (), connectionConfig?) -> connection<P...>,
	wait: (self: signal<P...>, connectionConfig?, P...) -> P...,
	fire: (self: signal<P...>, P...) -> ()
}

export type connection<P... = ...any> = {
	fire: (self: connection<P...>, P...) -> (),
	disconnect: (self: connection<P...>) -> ()
}


--// root
local constructors = {}


--// reusable threads
local threads = {} :: { thread }
local threadCount = 0

local function threadCell(callback, thread, ...)
	local ok, err = pcall(callback, ...)
	if not ok then
		warn(err)
	end
	threadCount += 1
	table.insert(threads, thread)
end

local function reusableThread()
	while true do
		threadCell(coroutine.yield())
	end
end


-- creates a new signal object

function constructors.new<P...>(config: signalConfig?): signal<P...>
	local signalConfig = signalConfig(config or {})
	
	local signal = {} :: signal<P...>
	
	local connections: { [number]: connection<P...> } = {}
	local connectionCount = 0
	
	local queue: { { any } }
	local latest
	if signalConfig.sticky ~= "latest" then
		queue = {}
	end
	
	local toRemove: { [connection]: true } = {}
	local indices: { [connection<P...>]: number } = {}
	
	local firing = false
	local function flushRemovals()
		for conn in toRemove do
			local index = indices[conn]
			local moved = connections[connectionCount]
			if moved then
				indices[moved] = index
			end
			connections[index] = moved
			connections[connectionCount] = nil
			indices[conn] = nil
			toRemove[conn] = nil
			connectionCount -= 1
		end
	end
	
	function signal:connect(callback, config)
		local connConfig = connectionConfig(config or {})
		local dispatchMethod = connConfig.dispatchMethod or signalConfig.dispatchMethod
		
		if queue and next(queue) then
			if signalConfig.sticky == "consume" and connConfig.consumeQueue then
				for i, args in queue do
					callback(table.unpack(args) :: any)
					queue[i] = nil
				end
			elseif signalConfig.sticky == "all" then
				for i, args in queue do
					callback(table.unpack(args) :: any)
				end
			end
		elseif signalConfig.sticky == "latest" and latest then
			callback(table.unpack(latest) :: any)
		end
		
		local connection = {} :: connection<P...>
		
		connectionCount += 1
		indices[connection] = connectionCount
		connections[connectionCount] = connection
		
		function connection:fire(...)
			if dispatchMethod == "immediate" then
				callback(...)
			else
				local thread: thread

				if threadCount == 0 then
					thread = coroutine.create(reusableThread)
					task.spawn(thread)
				else
					thread = threads[threadCount]
					threads[threadCount] = nil
					threadCount -= 1
				end

				task.spawn(thread, callback, thread, ...)
			end
		end
		
		function connection:disconnect()
			toRemove[connection] = true
			if not firing then
				flushRemovals()
			end
		end
		
		return connection
	end
	
	function signal:once(callback, config)
		local connection: connection<P...>
		connection = signal:connect(function(...)
			connection:disconnect()
			callback(...)
		end, config)
		return connection
	end
	
	function signal:wait(config, ...)
		local target = table.pack(...)
		local thread = coroutine.running()
		local connection: connection<P...>
		connection = signal:connect(function(...)
			if coroutine.status(thread) ~= "suspended" then
				return
			end
			
			local received = table.pack(...)
			if target.n > 0 then
				if target.n ~= received.n then
					return
				end
				
				for i, v in received do
					if target[i] ~= v then
						return
					end
				end
			end
			
			connection:disconnect()
			task.spawn(thread, ...)
		end, config)
		return coroutine.yield()
	end
	
	function signal:fire(...)
		firing = true
		
		-- append to queue
		local args = table.pack(...)
		if signalConfig.sticky == "latest" then
			latest = args
		else
			table.insert(queue, args)
		end
		
		for i = 1, connectionCount do
			local connection = connections[i]
			connection:fire(...)
		end
		
		if next(toRemove) then
			flushRemovals()
		end
		firing = false
	end
	
	return signal
end

local wrappedSignals: { [RBXScriptSignal]: signal } = {}
function constructors.wrap<P...>(robloxSignal: RBXScriptSignal, config: signalConfig?): signal<P...>
	local existing = wrappedSignals[robloxSignal]
	if existing then
		return existing
	end
	
	local signal = constructors.new(config)
	robloxSignal:Connect(function(...)
		signal:fire(...)
	end)
	
	wrappedSignals[robloxSignal] = signal
	return signal
end


--// return
return constructors