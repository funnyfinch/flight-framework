--[[ description:

]]
--!strict


--// services
local replicatedStorage = game:GetService("ReplicatedStorage")


--// modules
local modules = replicatedStorage.modules
local state = require(modules.state)


--// types
--native
export type springOptions<T> = {
	goal: state.typedSource<T>,
	frequency: number,
	damping: number
}



--// root
local motion = {}

function motion.spring<T>(state: state.typedSource<T>, options: springOptions<T>)
	
end


--// return
return motion