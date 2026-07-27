--[[ description:

	- this is a simpler version of the transport layer i have planned
	- once i have more time, i plan to rebuild the way playerSets are compiled

]]
--!strict


--// services
local encodingService = game:GetService("EncodingService")
local playerService = game:GetService("Players")
local replicatedStorage = game:GetService("ReplicatedStorage")
local runService = game:GetService("RunService")


--// modules
local modules = replicatedStorage.modules
local cleaner = require(modules.cleaner)
local scheduler = require(modules.scheduler)
local signal = require(modules.signal)
local state = require(modules.state)


--// constants
const reliableEvent, unreliableRemoteEvent = (function()
	local reliable = script:FindFirstChild("RemoteEvent")
	local unreliable = script:FindFirstChild("UnreliableRemoteEvent")

	if runService:IsServer() then
		reliable = reliable or Instance.new("RemoteEvent", script)
		unreliable = unreliable or Instance.new("UnreliableRemoteEvent", script)
	else
		assert(reliable and unreliable)
	end

	return reliable :: RemoteEvent, unreliable :: UnreliableRemoteEvent
end)()


--// types
--imported
export type writer = {
	buf: buffer?,
	offset: number,

	bits: (self: writer, bits: number, value: number) -> (),
	schema: (self: writer, schema: any, any) -> (),
	section: (self: writer, (writer) -> ()) -> (),
	alignByte: (self: writer) -> (),
	byteCount: (self: writer) -> number,

	bool: (self: writer, value: boolean) -> (),
	u8: (self: writer, value: number) -> (),
	u16: (self: writer, value: number) -> (),
	u32: (self: writer, value: number) -> ()
}

export type readContext = {
	player: Player
}

export type reader = {
	buf: buffer,
	offset: number,
	limit: number,

	bits: (self: reader, bits: number) -> number,
	schema: (self: reader, schema: any) -> any,
	section: (self: reader, (reader) -> ()) -> (),
	alignByte: (self: reader) -> (),
	skipBits: (self: reader, buts: number) -> (),

	bool: (self: reader) -> boolean,
	u8: (self: reader) -> number,
	u16: (self: reader) -> number,
	u32: (self: reader) -> number
}


--// root
local transport = {}


-------------------------------------------------------
--// groups


---------------
--// playerList
-- used for groups to derive from

transport.playerList = state.container<<Player, true>>()

local function addPlayer(player: Player)
	transport.playerList:set(player, true)
end

for _, player in playerService:GetPlayers() do
	task.spawn(addPlayer, player)
end
playerService.PlayerAdded:Connect(addPlayer)

playerService.PlayerRemoving:Connect(function(player)
	transport.playerList:set(player, nil)
end)

function transport.playerList:destroy()
	error("You cannot destroy this container")
end

---------------

export type group = state.container<Player, true>

transport.group = {}

function transport.group.static(players: { Player }): group
	local group = state.container<<Player, true>>()

	for _, player in players do
		group:set(player, true)
	end

	return group
end

-- derives a new group from the playerList via a predicate
function transport.group.derived(predicate: (Player) -> boolean): group
	local derived, i = state.container<<Player, true>>(), 1

	transport.playerList:each(function(player)
		local effect = state.react(function()
			if predicate(player) then
				derived:set(player, true)
				i += 1
			end
		end)

		return function()
			derived:set(player, nil)
			effect:destroy()
		end
	end)

	return derived :: group
end

transport.group.all = transport.group.derived(function() return true end)


-------------------------------------------------------
--// routes

export type route = {
	id: number,

	cleaner: cleaner.cleaner,
	markDirty: signal.signal<group?>,

	commit: (self: route, writer, group?) -> (),
	consume: (self: route, reader, readContext) -> (),
	clear: (self: route) -> ()
}

local liveRoutes: { [number]: route } = {}

local currentId = 0
function transport.route(id: number)
	assert(liveRoutes[id] == nil, `Route of id "{id}" already exists`)

	local route = {
		id = id,
		cleaner = cleaner.new(),
		markDirty = signal.new(),
	} :: route

	currentId = id + 1
	liveRoutes[id] = route
	return route
end


-------------------------------------------------------
--// channels

export type channel = {
	options: channelOptions,

	consume: (self: channel, reader, readContext) -> (),
	attach: (self: channel, route) -> () -> (),
}

export type channelOptions = {
	reliable: boolean,
	flushHertz: number
}

local channels: { [number]: channel } = {}

type playerSet = {
	players: { Player },
	dirty: { [route]: { [group]: true } }
}

local function getSetIdentifier(players: { Player }): string
	table.sort(players, function(a: Player, b: Player)
		return a.UserId < b.UserId
	end)

	local id = ""
	for i, player in players do
		id ..= `{i ~= 1 and "\0" or ""}{player.UserId}`
	end

	return id
end

local function getKeys<K>(t: { [K]: any }): { K }
	local keys, i = {}, 1
	for key in t do
		keys[i] = key
		i += 1
	end
	return keys
end

local function compilePlayerSets(from: { [route]: { [group]: true } }): { [string]: playerSet }
	local playerSets: { [string]: playerSet } = {}
	for route, groups in from do
		for group in groups do
			local groupId = getSetIdentifier(getKeys(group.children:peek()))
			local playerSet = playerSets[groupId]

			if not playerSet then
				playerSet = { players = getKeys(group.children:peek()), dirty = {} }
				playerSets[groupId] = playerSet
			end

			local dirtyGroups = playerSet.dirty[route]
			if not dirtyGroups then
				dirtyGroups = {}
				playerSet.dirty[route] = dirtyGroups
			end

			dirtyGroups[group] = true
		end
	end

	return playerSets
end

function transport.channel(id: number, options: channelOptions)
	assert(not channels[id], `Channel of id [{id}] already exists`)

	local channel = {
		options = table.freeze(options)
	} :: channel
	local cleaner = cleaner.new()

	local source = (options.reliable and reliableEvent or unreliableRemoteEvent) :: RemoteEvent

	local attachedRoutes: { [number]: route } = {}
	local dirtyLog: { [route]: { [group]: true } } = {}

	local flush = scheduler.rateLimit(scheduler.fromHertz(options.flushHertz))

	function channel:attach(route)
		assert(attachedRoutes[route.id] == nil, `Route of id [{route.id}] is already attached`)
		attachedRoutes[route.id] = route

		local conn = route.markDirty:connect(function(group)
			local dirtyGroups = dirtyLog[route]
			if not dirtyGroups then
				dirtyGroups = {}
				dirtyLog[route] = dirtyGroups
			end

			if group then
				dirtyGroups[group] = true
			end

			flush(function()
				local routes: { [route]: true } = {}

				if runService:IsServer() then
					local playerSets = compilePlayerSets(dirtyLog)

					for _, playerSet in playerSets do
						local payload = transport.buildBuffer(function(writer: writer)
							writer:u16(id)

							local len = 0; for route in playerSet.dirty do len += 1 end
							writer:u16(len)
							for route, groups in playerSet.dirty do
								routes[route] = true
								for group in groups do
									writer:u16(route.id)
									writer:section(function(writer)
										route:commit(writer, group)
									end)
								end
							end
						end)

						for _, player in playerSet.players do
							source:FireClient(player, payload)
						end
					end
				elseif runService:IsClient() then
					local payload = transport.buildBuffer(function(writer: writer)
						writer:u16(id)

						local len = 0; for route in dirtyLog do len += 1 end
						writer:u16(len)
						for route in dirtyLog do
							routes[route] = true
							writer:u16(route.id)
							writer:section(function(writer)
								route:commit(writer)
							end)
						end
					end)

					source:FireServer(payload)
				end

				for route in routes do
					if route.clear then
						route:clear()
					end
				end
				table.clear(dirtyLog)
			end)
		end)

		return function()
			conn:disconnect()
			attachedRoutes[route.id] = nil
		end
	end

	function channel:consume(reader, readContext)
		for _ = 1, reader:u16() do
			local routeId = reader:u16()
			local route = attachedRoutes[routeId]
			reader:section(function(reader)
				route:consume(reader, readContext)
			end)
		end
	end

	channels[id] = channel
	return channel
end


-------------------------------------------------------
--// networking

function transport.writer(buf: buffer?)
	local writer = {
		buf = buf,
		offset = 0,
	} :: writer

	function writer:bits(bitCount: number, value: number)
		if self.buf then
			buffer.writebits(self.buf, self.offset, bitCount, value)
		end
		self.offset += bitCount
	end

	function writer:bool(value: boolean)
		self:bits(1, value and 1 or 0)
	end

	function writer:u8(value)
		self:bits(8, value)
	end

	function writer:u16(value)
		self:bits(16, value)
	end

	function writer:u32(value)
		self:bits(32, value)
	end

	function writer:alignByte()
		local remainder = self.offset % 8
		if remainder ~= 0 then
			self.offset += 8 - remainder
		end
	end

	-- section format: u32 bitLength, then payload
	-- this costs 32 bits per dynamic section, but makes route/container skipping super simple
	function writer:section(write: (writer) -> ())
		local counter = transport.writer(nil)
		write(counter)

		self:bits(32, counter.offset)
		write(self)
	end

	function writer:byteCount(): number
		return math.ceil(self.offset / 8)
	end

	return writer
end

function transport.reader(buf: buffer, bitLimit: number?): reader
	local reader = {
		buf = buf,
		offset = 0,
		limit = bitLimit or (buffer.len(buf) * 8),
	} :: reader

	function reader:bits(bitCount: number): number
		if self.offset + bitCount > self.limit then
			error(`reader overflow: tried to read {self.offset + bitCount - self.limit} bits past section limit`)
		end
		local value = buffer.readbits(self.buf, self.offset, bitCount)
		self.offset += bitCount
		return value
	end

	function reader:bool(): boolean
		return self:bits(1) == 1
	end

	function reader:u8()
		return self:bits(8)
	end

	function reader:u16()
		return self:bits(16)
	end

	function reader:u32()
		return self:bits(32)
	end

	function reader:alignByte()
		local remainder = self.offset % 8
		if remainder ~= 0 then
			self.offset += 8 - remainder
		end
		if self.offset > self.limit then
			error("reader overflow after byte alignment")
		end
	end

	function reader:skipBits(bitCount: number)
		self.offset = math.min(self.offset + bitCount, self.limit)
	end

	function reader:section(readPayload: (reader) -> ())
		local bitCount = self:bits(32)
		local start = self.offset
		local sectionLimit = start + bitCount

		if sectionLimit > self.limit then
			error("section exceeds parent reader limit")
		end

		local sectionReader = transport.reader(self.buf, sectionLimit)
		sectionReader.offset = start

		local ok, err = pcall(function()
			readPayload(sectionReader)
		end)

		-- always land exactly at the end of the section, even on failure
		self.offset = sectionLimit

		if not ok then
			warn(`network section read failed and was skipped: {err}\n{debug.traceback()}`)
		end
	end

	return reader
end

function transport.buildBuffer(write: (writer) -> ()): buffer
	local counter = transport.writer(nil)
	write(counter)

	local buf = buffer.create(counter:byteCount())
	local writer = transport.writer(buf)
	write(writer)

	assert(writer.offset == counter.offset, "count/write pass mismatch")
	buf = encodingService:CompressBuffer(buf, Enum.CompressionAlgorithm.Zstd)
	return buf
end

-------------------------------------------------------
--// routing

if runService:IsServer() then
	local function handleEvent(source: RemoteEvent | UnreliableRemoteEvent, player: Player, payload: buffer)
		if typeof(payload) ~= "buffer" then
			return
		end

		payload = encodingService:DecompressBuffer(payload, Enum.CompressionAlgorithm.Zstd)
		local reader = transport.reader(payload)

		local channel = channels[reader:u16()]
		channel:consume(reader, { player = player })
	end

	reliableEvent.OnServerEvent:Connect(function(...)
		handleEvent(reliableEvent, ...)
	end)

	unreliableRemoteEvent.OnServerEvent:Connect(function(...)
		handleEvent(unreliableRemoteEvent, ...)
	end)
elseif runService:IsClient() then
	local function handleEvent(source: RemoteEvent | UnreliableRemoteEvent, payload: buffer)
		assert(typeof(payload) == "buffer", "Received non-buffer packet")

		payload = encodingService:DecompressBuffer(payload, Enum.CompressionAlgorithm.Zstd)
		local reader = transport.reader(payload)

		local channel = channels[reader:u16()]
		channel:consume(reader, {} :: any)
	end

	reliableEvent.OnClientEvent:Connect(function(...)
		handleEvent(reliableEvent, ...)
	end)

	unreliableRemoteEvent.OnClientEvent:Connect(function(...)
		handleEvent(unreliableRemoteEvent, ...)
	end)
end

transport.reliable = transport.channel(0, {
	reliable = true,
	flushHertz = 20
})

transport.unreliable = transport.channel(1, {
	reliable = false,
	flushHertz = 20
})


-------------------------------------------------------
--// generate route ids
--[[

	- transport routes are transmitted using numeric ids rather than strings
	- for example, a route for buying shop items may be assigned the id 2
	- using numeric ids reduces transport bandwidth, but hardcoding those ids would be tedious and error-prone
	
	- transport.id() provudes an ergonomic abstraction over this mapping
	- given a route name:
		- on the server, a unique numeric id is assigned
		- on the client, the corresponding id is requested from the server

]]

local getId = transport.route(0)
transport.reliable:attach(getId)
local requests: { [number]: string } = {}
local responses: { [number]: number } = {}
local idsByName: { [string]: number } = {}
local requestId = 0
local contracts: { [number]: signal.signal<number> } = {}

do
	local nameBits = math.ceil(math.log(20, 2))
	function getId:commit(writer)
		if runService:IsServer() then
			for id, resolvedId in responses do
				writer:u16(id)
				writer:u16(resolvedId)
			end
		else
			for id, name in requests do
				writer:u16(id)
				local length = #name
				writer:bits(nameBits, length)
				writer:alignByte()
				if writer.buf then
					buffer.writestring(writer.buf, writer.offset // 8, name, length)
				end
				writer.offset += length * 8
			end
		end
	end

	function getId:consume(reader, context)
		if runService:IsServer() then
			local requestId = reader:u16()
			local length = reader:bits(nameBits)
			reader:alignByte()
			if reader.offset + length * 8 > reader.limit then
				error(`exceeded limit by {reader.offset + length * 8 - reader.limit} bits`)
			end
			local name = buffer.readstring(reader.buf, reader.offset // 8, length)
			reader.offset += length * 8
			local id = idsByName[name]
			if id then
				responses[requestId] = id
				getId.markDirty:fire(transport.group.static { context.player })
			end
		else
			local id = reader:u16()
			local contract = contracts[id]
			contract:fire(reader:u16())
		end
	end
	
	function getId:clear()
		table.clear(requests)
		table.clear(responses)
	end
end

function transport.id(name: string)
	if runService:IsServer() then
		currentId += 1
		idsByName[name] = currentId
		return currentId
	elseif runService:IsClient() then
		local contract = signal.new<<(number)>>()
		requests[requestId] = name
		contracts[requestId] = contract
		requestId += 1
		getId.markDirty:fire()
		return contract:wait()
	end
	error(`Could not fetch id for "{name}"`)
end



--// return
return transport