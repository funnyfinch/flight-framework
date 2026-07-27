--[[ description:

	- this is a simpler version of the network layer i have planned
	- once i have more time, i plan to rebuild the way playerSets are compiled

]]
--!strict


--// services
local runService = game:GetService("RunService")


--// modules
local schemas = require("./schemas")
local signal = require("./signal")
local transport = require("@self/transport")


--// types
--imported
type innerof<T> = schemas.innerof<T>
type writer = transport.writer
type reader = transport.reader




--// root
local network = {}


-------------------------------------------------------
--// default routes

--// packets
--[[
	
	- one-way messages
	- sent without expecting a response
	
]]

export type packet<schema = any> = transport.route & {
	-- server only
	fireTo: typeof(function(self: packet<schema>, group: transport.group, payload: innerof<schema>) end),
	-- from client: fires to server
	-- from server: fires to all clients
	fire: typeof(function(self: packet<schema>, payload: innerof<schema>) end),

	serverReceived: signal.signal<Player, innerof<schema>>,
	clientReceived: signal.signal<innerof<schema>>
}

function network.packet<schema>(id: number, schema: schema): packet<schema>
	local packet = transport.route(id) :: packet<schema>
	packet.serverReceived = signal.new()
	packet.clientReceived = signal.new()
	
	---------------
	local packets: { (writer) -> () } = {}

	function packet:commit(writer)
		writer:u16(#packets)
		for _, packet in packets do
			packet(writer)
		end
	end

	function packet:consume(reader, readContext)
		for _ = 1, reader:u16() do
			local result = reader:schema(schema)
			if runService:IsServer() and readContext.player then
				packet.serverReceived:fire(readContext.player, result)
			else
				packet.clientReceived:fire(result)
			end
		end
	end
	
	function packet:clear()
		table.clear(packets)
	end
	
	---------------
	function packet:fireTo(group, payload)
		assert(runService:IsServer(), "packet:fireTo() can only be used on the server")

		table.insert(packets, function(writer: writer)
			writer:schema(schema, payload)
		end)

		packet.markDirty:fire(group)
	end

	function packet:fire(payload)
		local group: transport.group?
		if runService:IsServer() then
			group = transport.group.all
		end
		table.insert(packets, function(writer: writer)
			writer:schema(schema, payload)
		end)
		packet.markDirty:fire(group)
	end

	return packet
end


--// queries
--[[

	- request-response messages
	- the sender expects a value to be returned

]]

export type queryContract<response> =  {
	received: signal.signal<innerof<response>>,
	--raw: signal.signal<response>
}

export type query<request, response> = transport.route & {
	request: (self: query<request, response>, innerof<request>) -> queryContract<response>,
	respond: (innerof<request>) -> innerof<response>,
}

function network.query<req, res>(id: number, request: req, response: res): query<req, res>
	---------------
	--// internals

	local query = transport.route(id) :: query<req, res>

	type serializer = (writer) -> ()
	local requests: { serializer } = {}
	local responses: { serializer } = {}
	local contracts: { [number]: queryContract<res> } = {}

	function query:commit(writer, group)
		writer:u16(#requests)
		for _, request in requests do
			request(writer)
		end

		writer:u16(#responses)
		for _, response in responses do
			response(writer)
		end

		query.markDirty:fire(group)
	end

	function query:consume(reader, readContext)
		local handler = query.respond

		for _ = 1, reader:u16() do
			local requestId = reader:u16()
			local arg = request and reader:schema(request)
			local result = handler(arg)

			table.insert(responses, function(writer: writer)
				writer:u16(requestId)
				if response then
					writer:schema(response, result)
				end
			end)
			
			query.markDirty:fire(transport.group.static { readContext.player })
		end
		
		for _ = 1, reader:u16() do
			local responseId = reader:u16()
			local contract = contracts[responseId]
			if contract then
				local value = response and reader:schema(response)
				contract.received:fire(value)
			end
			query.markDirty:fire()
		end
	end

	function query:clear()
		table.clear(requests)
		table.clear(responses)
	end

	---------------
	--// public api

	local rollingContractId = 1
	local function newContract(id: number): queryContract<res>
		local contract = {
			received = signal.new { sticky = "all" }
		} :: queryContract<res>

		local received: innerof<res>
		
		
		local internalConnect = contract.received.connect
		function contract.received:connect(callback, ...): signal.connection<innerof<res>>?
			if received then
				callback(received)
			else
				return internalConnect(contract.received, function(value)
					received = value
					callback(value)
				end, ...)
			end
			return nil
		end
		
		contracts[id] = contract
		return contract
	end

	function query:request(arg)
		assert(runService:IsClient(), "Requests can only be used from the client")
		
		local id = rollingContractId
		rollingContractId += 1

		table.insert(requests, function(writer: writer)
			writer:u16(id)
			if request then
				writer:schema(request, arg)
			end
		end)
		
		local contract = newContract(id)
		query.markDirty:fire()

		return contract
	end

	return query
end


--// return
return setmetatable(network, { __index = transport })