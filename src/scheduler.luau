--[[description:

	- handles deterministic frame

]]
--!strict


--// services
local replicatedStorage = game:GetService("ReplicatedStorage")
local runService = game:GetService("RunService")


--// modules
local modules = replicatedStorage.modules
local cleaner = require(modules.cleaner)
local signal = require(modules.signal)


--// constants
local FRAME_HERTZ = 20
local FRAME_DELTA = 1 / FRAME_HERTZ


--// types
--imported
type signal<P... = ...any> = signal.signal<P...>

--native
export type job = {
	cleaner: cleaner.cleaner,
	
	shift: (self: job, frames: number) -> (),
	reset: (self: job) -> (),
	
	pause: (self: job) -> (),
	destroy: (self: job) -> ()
}


--// root
local scheduler = {
	step = signal.new() :: signal<number>
}

local frame = workspace:GetServerTimeNow() // FRAME_DELTA

local function newJob(): job
	local job = {
		cleaner = cleaner.new()
	} :: job
	
	function job:destroy()
		
	end
	
	return job
end

function scheduler.frame()
	return frame
end

-- converts seconds to frames
function scheduler.seconds(seconds: number): number
	return seconds * FRAME_HERTZ
end

-- gets frame interval from hertz
function scheduler.fromHertz(hertz: number): number
	return FRAME_DELTA / (1 / hertz)
end

function scheduler.at(targetFrame: number)
	
	
	return newJob()
end

function scheduler.wait(frames: number?)
	return newJob()
end

-- fixed = relative to root rather than local time
function scheduler.every(frames: number, callback: (frame: number) -> (), fixed: boolean?)
	local job = newJob()
	local nextTick = frame + frames
	
	scheduler.step:connect(function(frame)
		if frame >= nextTick then
			callback(frame)
			nextTick += frames
		end
	end)
	
	return job
end

function scheduler.delay(frames: number, callback: (frame: number) -> ()): job
	local job = newJob()
	
	local target = frame + frames
	scheduler.step:connect(function(frame)
		if frame == target then
			callback(frame)
			--job:destroy()
		end
	end)

	return job
end

-- TODO: perhaps determine better name than debounce
type debounceJob = setmetatable<job, { __call: (any) -> () }>
function scheduler.debounce(frameDuration: number, callback: (frame: number) -> ()): debounceJob
	local controller = newJob()
	local pending: job
	
	local mt = getmetatable(controller) or {}
	mt.__call = function()
		print('called', pending)
		if pending then
			pending:reset()
		else
			pending = controller.cleaner:give(scheduler.delay(frameDuration, function(frame)
				(pending :: job):destroy()
				callback(frame)
			end))
		end
	end
	setmetatable(controller, mt)
	
	return controller :: any
end

function scheduler.rateLimit(minimum: number)
	local last = 0
	return function(callback: (frame: number) -> ()): job
		if frame - last >= minimum then
			last = frame
			callback(frame)
		else
			return scheduler.delay(last + minimum, function()
				last = frame
				callback(frame)
			end)
		end
	end
end

function scheduler.next(callback: (frame: number) -> ())

end

runService.Heartbeat:Connect(function(delta)
	local thisFrame = workspace:GetServerTimeNow() // FRAME_DELTA

	while frame < thisFrame do
		frame += 1
		scheduler.step:fire(frame)
	end
end)



--// return
return scheduler