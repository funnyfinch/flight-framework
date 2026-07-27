--[[ description:

]]
--!strict


--// services
local dataStoreService = game:GetService("DataStoreService")
local encodingService = game:GetService("EncodingService")
local playerService = game:GetService("Players")
local runService = game:GetService("RunService")


--// modules
local cleaner = require("./cleaner")
local network = require("./network")
local schemas = require("./schemas")
local signal = require("./signal")
local state = require("./state")

local dataFactory = require("./storage/playerData")


--// types
--native
type treeData = schemas.innerof<typeof(dataFactory)>
type tree = typeof(dataFactory._instanceType)

export type player = tree & {
	player: Player,
	data: tree,
	cleaner: cleaner.cleaner,
}


type updateStage = "loading" | "saving" | "releasing"
export type updateParams = {
	stage: updateStage,
	player: Player
}

export type updateResult = {
	successful: boolean,
	exit: string?,
	data: treeData?
}


--// root
local players = {
	list = {} :: { [Player]: player },
	playerAdded = signal.new<<(player)>>(),
	playerRemoving = signal.new<<(player)>>(),
	localPlayerAdded = signal.new<<(player)>>{ sticky = "latest" } -- client only
}
local loadingThreads: { [Player]: thread } = {}

local dataStore: DataStore
if runService:IsServer() then
	dataStore = dataStoreService:GetDataStore("playerData")
end


local function storeKey(player: Player): string
	return `{player.UserId}`
end

local function updateAsync(params: updateParams): updateResult
	local result = {
		successful = false
	} :: updateResult
	
	dataStore:UpdateAsync(storeKey(params.player), function(record: buffer?): buffer
		if not record then
			local data = dataFactory:raw { userId = params.player.UserId }
			result.data = data
			
			result.successful = true
			return network.buildBuffer(function(writer)
				print(data)
				dataFactory.serialize(writer, data)
			end)
		else
			record = encodingService:DecompressBuffer(record, Enum.CompressionAlgorithm.Zstd)
			
			if params.stage == "loading" then
				result.successful = true
				return record
			else
				-- saving or releasing
				return record
			end
		end
	end)
	
	return result
end

if runService:IsServer() then
	signal.wrap<<(Player)>>(playerService.PlayerAdded):connect(function(instance)
		loadingThreads[instance] = coroutine.running()

		dataStore:RemoveAsync(storeKey(instance))
		local result = updateAsync {
			stage = "loading",
			player = instance
		}
		if not result.successful then
			instance:Kick(`Could not fetch data: {result.exit or "UNKNOWN"}`)
		end

		local tree = dataFactory:instance({ owner = instance }, result.data :: treeData)
		local player: player = setmetatable({
			cleaner = cleaner.new(),
			player = instance,
			tree = tree
		} :: any, { __index = tree })

		loadingThreads[instance] = nil
		players.list[instance] = player

		player.cleaner:give(function()
			players.list[instance] = nil
		end)

		players.playerAdded:fire(player)
	end, { dispatchMethod = "deferred" })

	signal.wrap<<(Player)>>(playerService.PlayerRemoving):connect(function(instance)
		local thread = loadingThreads[instance]
		if thread then
			coroutine.close(thread)
		end

		local player = players.list[instance]
		if player then
			players.playerRemoving:fire(player)
			player.cleaner:cleanup()
		end
	end, { dispatchMethod = "deferred" })
else
	local function getPlayerByUserId(userId: number): Player?
		for _, player in playerService:GetPlayers() do
			if player.UserId == userId then
				return player
			end
		end
		return nil
	end
	
	local playersByTree: { [schemas.instance<any>]: player } = {}
	dataFactory.instanceAdded:connect(function(tree)
		local instance = getPlayerByUserId(tree.userId:peek())
		assert(instance)
		
		local player: player = setmetatable({
			cleaner = cleaner.new(),
			player = instance,
			tree = tree
		} :: any, { __index = tree })
		
		player.cleaner:give(function()
			table.clear(player)
		end)
		
		playersByTree[tree] = player
		players.playerAdded:fire(player)
	end)
	dataFactory.instanceRemoving:connect(function(tree)
		local player = playersByTree[tree]
		if player then
			players.playerRemoving:fire(player)
			player.cleaner:cleanup()
		end
	end)
end


--// client
if runService:IsClient() then
	local conn: signal.connection<player>; conn = players.playerAdded:connect(function(player)
		if player.player == playerService.LocalPlayer then
			conn:disconnect()
			players.localPlayerAdded:fire(player)
		end
	end)
end


--// return
return players