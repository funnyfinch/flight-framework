--[[ description:

	

]]
--!strict


--// services

local runService = game:GetService("RunService")


--// modules
local leader = require("./leader")
local scheduler = require("./scheduler")
local signal = require("./signal")
local state = require("./state")
local transport = require("./network/transport")
local utils = require("./utils")
	local index = require("./utils/index")


--// constants
local MAP_EXPIRATION = leader.LEASE_DURATION + 2
local ZSTD = Enum.CompressionAlgorithm.Zstd


--// types
--functions
type function getinnerof(ty: type)
	if ty:is("any") or ty:is("nil") then
		return ty
	end

	if ty:is("table") then
		return ty:readproperty(types.singleton("__inner")) :: type
	elseif ty:is("intersection") or ty:is("union") then
		for _, component in ty:components() do
			local inner = getinnerof(component)
			if inner then
				return inner
			end
		end
	else
		return ty
	end

	error("Could not get type")
end

type function getinnerlist(ty: type)
	local out = types.newtable()

	if ty:is("intersection") or ty:is("union") then
		for _, component in ty:components() do
			for key, prop in getinnerlist(component):properties() do
				out:setproperty(key, prop)
			end
		end
	elseif ty:is("table") then
		for key, prop in ty:properties() do
			local propType = prop.write or prop.read
			if propType then
				local inner = getinnerof(propType)
				if inner then
					out:setproperty(key, inner)
				end
			end
		end
	end

	return out
end

type function writeable(ty: type)
	local out = types.newtable()

	if ty:is("table") then
		for key, prop in ty:properties() do
			if prop.write then
				out:setproperty(key, types.optional(prop.write))
			end
		end
	elseif ty:is("intersection") then
		for _, component in ty:components() do
			for key, prop in component:properties() do
				out:setproperty(key, prop.write)
			end
		end
	end

	return out
end

export type innerof<T> = getinnerof<T>
export type innerlist<T> = getinnerlist<T>

--imported
type writer = transport.writer
type reader = transport.reader

--native
export type schema<inner = any> = setmetatable<{
	-- meta
	__inner: inner,
	default: inner,

	-- definition
	serialize: (writer, inner) -> (),
	deserialize: (reader) -> inner,
	validate: (any) -> boolean,
	instance: (self: schema<inner>, inner, (schema) -> ()?) -> schema<inner>,
	view: <T>(self: schema<inner>, projection: (schema<inner>) -> T) -> T,

	-- state
	id: number,
	updated: signal.signal<>,
	commit: (self: schema<inner>, writer) -> (),
	consume: (self: schema<inner>, reader) -> (),
	buffer: (self: schema<inner>) -> buffer,
	index: (self: schema<inner>, ...any) -> schema<inner>,
}, { __call: <T>(T, any) -> T }>


--// root
local schemas = {}


--// helpers

local function makeConstructor<T>(constructor: (T) -> ()): T
	local schema = {
		updated = signal.new()
	} :: schema
	setmetatable(schema, { __call = function(_, default)
		local cloned = utils.clone(schema)
		cloned.default = default
		return cloned
	end })
	
	constructor(schema)
	return schema
end


local function unsignedCountBits(value: number): number
	assert(value >= 0 and value % 1 == 0)

	local bits = 0
	repeat
		bits += 1
		value //= 2
	until value == 0

	return bits
end


--// values

export type value<T = any> = state.value<T> & schema<T> & {
	inner: (self: value<T>) -> T
}

local function makeValue<T>(constructor: (T) -> ()): T
	return makeConstructor<<T>>(function(schema: value<T>)
		function schema:view(projection)
			local view = {
				base = self,
				projection = projection,
			}

			function view:instance(...)
				local state = (self.base :: any):instance(...)
				local projection = self.projection

				return setmetatable({
					base = state,

					get = function()
						return projection(state)
					end,

					peek = function()
						return projection(state)
					end,
				}, {
					__index = state,
				})
			end

			return setmetatable(view :: any, {
				__index = self,
			})
		end

		function schema:inner()
			return self:view(function(value: any)
				return (value :: value):peek()
			end)
		end
		
		function schema:instance(value, hook)
			value = value or self.default
			assert(value)
			local instance = index(state.value(value)) :: value
			instance:index(schema)
			instance.changed:connect(function()
				instance.updated:fire()
			end)
			
			function instance:commit(writer)
				local value = instance:get()
				schema.serialize(writer, value)
			end
			function instance:consume(reader)
				local value = schema.deserialize(reader)
				instance:set(value)
			end
			
			if hook then
				hook(instance)
			end
			return instance
		end

		constructor(schema)
	end)
end

schemas.bool = makeValue<<value<boolean>>>(function(schema)
	function schema.serialize(writer, value)
		writer:bits(1, value == true and 1 or 0)
	end

	function schema.deserialize(reader)
		return reader:bits(1) == 1
	end

	function schema.validate(value)
		return type(value) == "boolean"
	end
end)

function schemas.unsigned(bits: number)
	local range = 2 ^ bits
	return makeValue<< value<number> >>(function(schema)
		function schema.serialize(writer: writer, number: number)
			return writer:bits(bits, number)
		end
		function schema.deserialize(reader)
			return reader:bits(bits)
		end
		function schema.validate(value: any)
			return type(value) == "number" and value % 1 == 0 and value >= 0 and value < range - 1
		end
	end)
end

function schemas.signed(bits: number)
	local shift = 2 ^ (bits - 1)
	local range = 2 ^ bits
	return makeValue<< value<number> >>(function(schema)
		function schema.serialize(writer: writer, number: number)
			if number > shift then
				number += shift
			end
			writer:bits(bits, number)
		end
		function schema.deserialize(reader: reader)
			local number = reader:bits(bits)
			if number > shift then
				number -= shift
			end
			return number
		end
		function schema.validate(value: any)
			-- shifting unsigned ints to be positive for simplicity
			return type(value) == "number" and value % 1 == 0 and value >= 0 and value + shift < range
		end
	end)
end

schemas.u8 = schemas.unsigned(8)
schemas.u16 = schemas.unsigned(16)
schemas.u32 = schemas.unsigned(32)
schemas.i8 = schemas.unsigned(8)
schemas.i16 = schemas.unsigned(16)
schemas.i32 = schemas.unsigned(32)


function schemas.range(min: number, max: number)
	local range = max - min
	assert(range >= 0)
	local bits = math.ceil(math.log(range, 2))
	local shift = min * -1

	return makeValue<< value<number> >>(function(schema)
		function schema.serialize(writer: writer, number: number)
			number = number + shift
			writer:bits(bits, number)
		end
		function schema.deserialize(reader: reader)
			return reader:bits(bits) - shift
		end
		function schema.validate(value: any)
			return type(value) == "number" and value % 1 == 0 and value >= min and value <= max
		end
	end)
end

function schemas.decimal(integerBits: number, decimalPlaces: number)
	local maxRange = 10 ^ decimalPlaces
	local decimalBits = math.ceil(math.log(maxRange, 2))
	local bits = integerBits + decimalBits

	return makeConstructor<< value<number> >>(function(schema)
		function schema.serialize(writer: writer, number: number)
			writer:bits(bits, number + (number - math.floor(number)) * maxRange)
		end
		function schema.deserialize(reader: reader)
			return reader:bits(integerBits) + reader:bits(decimalBits) / maxRange
		end
		function schema.validate(value: any)
			return type(value) == "number" and value >= 0 and value <= 2 ^ integerBits + 1
		end
	end)
end

function schemas.string(maxLength: number)
	local lengthBits = unsignedCountBits(maxLength)
	return makeValue<<value<string>>>(function(schema)
		function schema.serialize(writer, value)
			local length = #value
			writer:bits(lengthBits, length)
			writer:alignByte()
			if writer.buf then
				buffer.writestring(writer.buf, writer.offset // 8, value, length)
			end
			writer.offset += length * 8
		end

		function schema.deserialize(reader, value)
			local length = reader:bits(lengthBits)
			reader:alignByte()
			if reader.offset + length * 8 > reader.limit then
				error(`exceeded limit by {reader.offset + length * 8 - reader.limit} bits`)
			end
			local value = buffer.readstring(reader.buf, reader.offset // 8, length)
			reader.offset += length * 8
			return value
		end

		function schema.validate(value)
			return type(value) == "string" and #value <= maxLength
		end
	end)
end

--// composite values

function schemas.enum<T>(values: T)
	local valuesByName = values :: { [string]: number }
	local namesByValue: { [number]: string } = {}
	local maxValue = 0

	for name, id in valuesByName do
		assert(type(id) == "number" and id % 1 == 0 and id >= 0, "enum ids must be unsigned integers")
		assert(namesByValue[id] == nil, "duplicate enum id")
		namesByValue[id] = name
		maxValue = math.max(maxValue, id)
	end

	local bits = unsignedCountBits(maxValue)

	return makeValue<<value<keyof<T>>>>(function(schema)
		function schema.serialize(writer, value)
			writer:bits(bits, valuesByName[value])
		end

		function schema.deserialize(reader): string
			local id = reader:bits(bits)
			local name = namesByValue[id]
			if name == nil then
				error(`unknown enum id {id}`)
			end
			return name
		end

		function schema.validate(value)
			return type(value) == "string" and valuesByName[value] ~= nil
		end
	end)
end

export type optional<T> = T & {
	exists: (self: optional<T>) -> boolean,
	clear: (self: optional<T>) -> ()
}

function schemas.optional<T>(schema: T)
	local schema = schema :: schema
	return makeValue<<optional<T>>>(function(optionalSchema: schema)
		function optionalSchema.serialize(writer, value)
			writer:bool(value ~= nil)
			if value ~= nil then
				schema.serialize(writer, value)
			end
		end

		function optionalSchema.deserialize(reader): any?
			local present = reader:bool()
			if not present then
				return nil
			end
			return schema.deserialize(reader)
		end

		function optionalSchema.validate(value)
			if value == nil then
				return true
			end
			return schema.validate(value)
		end
	end)
end


-------------------------------------------------------
--// containers
--[[

	- there are two types of containers:
	- arrays: function similarly to lua tables. values must be keyed by numbers
	- maps: dictionary where you can freely select the key and value schemas

]]

export type container<K = schema, V = schema> = schema<{ [K]: V }> & {
	keySchema: K,
	valueSchema: V,
	countSchema: schema,
	updated: signal.signal<>,
	create: (self: container<K, V>, innerof<K>, innerof<V>) -> (),
	resolve: (self: container<K, V>, innerof<K>, innerof<V>) -> ()
} & state.container<K, V>

local function makeContainer<T>(constructor: (T) -> ()): T
	return makeConstructor<<T>>(function(container: container)
		function container:instance(entries, hook)
			local instance = index(state.container()) :: container
			instance:index(container)
			
			function instance:commit(writer)
				container.countSchema.serialize(writer, instance.length:peek())
				for key, value in instance:iter() do
					container.keySchema.serialize(writer, key)
					container.valueSchema.serialize(writer, value)
				end
			end
			
			function instance:consume(reader)
				for _ = 1, container.countSchema.deserialize(reader) do
					local key = container.keySchema.deserialize(reader)
					local existing = instance:get(key)
					if existing then
						existing:consume(reader)
					else
						instance:create(key, container.valueSchema.deserialize(reader))
					end
				end
			end
			
			function instance:create(key, value)
				local key = container.keySchema:instance(key, hook)
				local value = container.valueSchema:instance(value, hook)
				instance:set(key, value)
			end
			
			if entries then
				for key, value in entries do
					instance:create(key, value)
				end
			end
			
			return instance
		end
		constructor(container)
	end)
end

function schemas.array<T>(maxLength: number?, valueSchema: T): container<number, T>
	local valueSchema = valueSchema :: schema
	local maxLength = maxLength or 2^8

	local countBits = unsignedCountBits(maxLength)
	local countSchema = schemas.unsigned(countBits)

	return makeContainer<<container<number, T>>>(function(schema)
		function schema.serialize(writer, elements)
			local len = 0
			for _ in elements do len += 1 end
			writer:schema(countSchema, len)
			for k, v in elements do
				writer:schema(countSchema, k)
				writer:schema(valueSchema, v)
			end
		end

		function schema.deserialize(reader)
			local out = {}
			local count = reader:schema(countSchema)
			for _ = 1, count do
				local key = reader:schema(countSchema)
				local value = reader:schema(valueSchema)
				out[key] = value
			end
			return out
		end

		function schema.validate(elements)
			if type(elements) ~= "table" then
				return false
			end

			local n = 0
			for i, v in elements do
				n += 1
				if n > 2 ^ countBits then
					return false
				end

				if not valueSchema.validate(v) then
					return false
				end
			end

			return true
		end
	end)
end

function schemas.map<K, V>(keySchema: K, valueSchema: V, maxLength: number?): container<K, V>
	local keySchema, valueSchema = keySchema :: schema, valueSchema :: schema

	local countBits = maxLength and unsignedCountBits(maxLength) or 8
	local countSchema = schemas.unsigned(countBits)

	return makeContainer<<container<K, V>>>(function(schema)
		schema.keySchema = keySchema
		schema.valueSchema = valueSchema
		schema.countSchema = countSchema

		function schema.serialize(writer, fields)
			local len = 0
			for _ in fields do len += 1 end
			countSchema.serialize(writer, len)
			for k, v in fields do
				keySchema.serialize(writer, k)
				valueSchema.serialize(writer, v)
			end
		end

		function schema.deserialize(reader)
			local out = {}
			local count = countSchema.deserialize(reader)
			for _ = 1, count do
				local key = keySchema.deserialize(reader)
				local value = valueSchema.deserialize(reader)
				out[key] = value
			end
			return out
		end

		function schema.validate(fields)
			if type(fields) ~= "table" then
				return false
			end

			local i = 0
			for k, v in fields do
				i += 1
				if i > 2 ^ countBits  then
					return false
				end

				if not keySchema.validate(k) then
					return false
				end
				if not valueSchema.validate(v) then
					return false
				end
			end

			return true
		end
	end)
end


export type struct<shape> = schema<innerlist<shape>> & setmetatable<{}, { __index: shape }>

function schemas.struct<shape>(shape: shape): struct<shape>
	local shape = shape :: { [string]: schema }

	type field = {
		id: number,
		key: string,
		schema: schema
	}

	local fieldsById: { field } = {}
	local fieldsByKey: { [string]: field } = {}

	for key, schema in shape do
		local field = {
			key = key,
			schema = schema
		} :: field

		table.insert(fieldsById, field)
		fieldsByKey[key] = field
	end

	table.sort(fieldsById, function(a: field, b: field)
		return a.key < b.key
	end)

	for id, field in ipairs(fieldsById) do
		field.id = id
	end

	local fieldCount = #fieldsById
	local countSchema = schemas.unsigned(unsignedCountBits(fieldCount))
	
	return makeConstructor<<struct<shape>>>(function(schema)
		schema = index(schema) :: struct<shape>
		schema:index(function(_, key: any)
			local field = fieldsByKey[key] or fieldsById[key]
			return field and field.schema
		end)

		local mt = getmetatable(schema :: any)
		mt.__iter = function(self)
			local i = 0
			return function()
				i += 1
				local field = fieldsById[i]
				local instance = self[i]
				if instance then
					return field.key, self[i]
				end
				return nil :: any
			end
		end
		setmetatable(schema :: schema, mt)

		function schema.serialize(writer: writer, fields: { [string]: any })
			local len = 0; for _ in fields do len += 1 end
			countSchema.serialize(writer, len)
			
			for key, value in fields do
				local field = fieldsByKey[key]
				countSchema.serialize(writer, field.id)
				field.schema.serialize(writer, value)
			end
		end
		function schema.deserialize(reader: reader)
			local out = {}
			for _ = 1, countSchema.deserialize(reader) do
				local id = countSchema.deserialize(reader)
				local field = fieldsById[id]
				out[field.key] = field.schema.deserialize(reader)
			end
			return out :: innerlist<shape>
		end
		function schema.validate(fields: { [any]: any })
			if type(fields) ~= "table" then
				return false
			end

			for key, value in fields do
				local field = fieldsByKey[key]
				if not field then
					return false
				end

				if not field.schema.validate(value) then
					return false
				end
			end

			return true
		end
		function schema:instance(data: { [any]: any }, hook)
			data = data or {}
			local instance = index {
				updated = signal.new()
			} :: struct<shape>

			local instancedById: { [number]: schema } = {}
			local instancedByKey: { [string]: schema } = {}

			instance:index(function(_, key: any)
				local state = instancedById[key] or instancedByKey[key]
				return state or schema[key]
			end)

			local mt = getmetatable(instance :: any)
			mt.__iter = function(self)
				local i = 0
				return function()
					i += 1
					local field = fieldsById[i]
					local instance = instancedById[i]
					if instance then
						return field.key, instance
					end
					return nil :: any
				end
			end
			setmetatable(instance :: schema, mt)

			for id, field in fieldsById do
				local value = data and data[field.key] or field.schema.default
				local instance = field.schema:instance(value, hook)
				instancedById[id] = instance
				instancedByKey[field.key] = instance
			end

			function instance:commit(writer)
				countSchema.serialize(writer, fieldCount)
				for id, instance in instancedById do
					countSchema.serialize(writer, id)
					instance:commit(writer)
				end
			end

			function instance:consume(reader)
				for _ = 1, countSchema.deserialize(reader) do
					local id = countSchema.deserialize(reader)
					local instance = instancedById[id]
					instance:consume(reader)
				end
			end

			function instance:buffer()
				return transport.buildBuffer(function(writer)
					instance:commit(writer)
				end)
			end
			
			if hook then
				hook(instance)
			end
			return instance
		end
	end)
end

export type tree<shape> = struct<shape> & {
	descendantChanged: signal.signal<schema>,
	raw: (self: tree<shape>) -> innerlist<shape>
}

function schemas.tree<shape>(shape: shape, data: innerlist<shape>?, hook: (schema) -> ()?): tree<shape>
	local data = data :: { [string]: any }
	local shape = shape :: { [string]: schema }

	local tree = index {} :: tree<shape>
	local descendantChanged = signal.new()

	type keyedInstance = schema & { key: string }
	
	local id = 0
	local function instanceHook(state: schema)
		local state = state :: schema
		id += 1
		state.id = id

		state.updated:connect(function()
			descendantChanged:fire(state)
		end)
		if hook then
			hook(state)
		end
	end

	local struct = schemas.struct(shape):instance(data, instanceHook)
	tree:index(struct)
	
	local function raw(schema)
		if schema.iter then
			local out = {}
			for key, value in schema:iter() do
				out[raw(key)] = raw(value)
			end
			return out
		elseif schema.get then
			return schema:get()
		end

		local out = {}
		for key, value in schema do
			out[key] = raw(value)
		end
		return out
	end

	function tree:raw()
		return raw(struct)
	end
	
	local mt = getmetatable(tree :: any)
	mt.__iter = function(self)
		local i = 0
		return function()
			local n = i
			i += 1
			local instance = self[n]
			if instance then
				return n, instance
			end
			return nil :: any
		end
	end
	setmetatable(tree :: any, mt)

	return tree :: tree<shape>
end

export type policyGroup<meta = any> = setmetatable<{
	predicate: (meta, Player) -> boolean,
	default: (self: policyGroup<meta>) -> policyGroup<meta>
}, { __call: <T>(policyGroup<meta>, T) -> T }>

export type policy<meta = any> = {
	default: policyGroup<meta>,
	group: (self: policy<meta>, (meta, Player) -> boolean) -> policyGroup<meta>,
	instance: (self: policy<meta>, meta) -> (policyGroup<meta>) -> transport.group
}

function schemas.policy<meta>(): policy<meta>
	local policy = {} :: policy<meta>

	function policy:group(predicate)
		local group: policyGroup<meta> = setmetatable({
			predicate = predicate
		} :: any, { __call = function(group, schema)
			schema.group = group
			return schema
		end })

		-- handle default
		if not policy.default then
			policy.default = group
		end
		function group:default()
			policy.default = group
			return group
		end

		return group
	end

	function policy:instance(meta)
		local instancedGroups: { [policyGroup<meta>]: transport.group } = {}
		return function(policyGroup: policyGroup<meta>)
			local instanced = instancedGroups[policyGroup]
			if instanced then
				return instanced
			end

			local derived = state.container<<Player, true>>() :: transport.group

			transport.playerList:each(function(player)
				local effect = state.react(function()
					derived:set(player, policyGroup.predicate(meta, player) and true or nil)
				end)

				return function()
					derived:set(player, nil)
					effect:destroy()
				end
			end)

			return derived
		end
	end

	return policy
end

export type instance<shape> = tree<shape> & {
	states: { [number]: schema },
	dirty: { [number]: schema },
	markDirty: signal.signal<schema>
}

export type factory<meta, shape> = schema<innerlist<shape>> & {
	_instanceType: instance<shape>,
	
	instanceAdded: signal.signal<instance<shape>>,
	instanceRemoving: signal.signal<instance<shape>>,
	
	instance: (self: factory<meta, shape>, meta, innerlist<shape>) -> instance<shape>,
	raw: (self: factory<meta, shape>, override: writeable<innerlist<shape>>) -> innerlist<shape>,
	replicate: (self: factory<meta, shape>, id: string) -> transport.route,
}

function schemas.factory<meta, shape>(policy: policy<meta>, shape: shape)
	local shape = shape :: { [string]: schema }
	local struct: struct<shape> = schemas.struct(shape) :: any

	local factory = index {
		instanceAdded = signal.new { sticky = "all" },
		instanceRemoving = signal.new()
	} :: factory<meta, shape>

	local instances: { [number]: instance<shape> } = {}
	local newInstances: { [number]: instance<shape> } = {}
	local instanceId = 0
	local dirtyInstances: { [number]: true } = {}
	
	local function createInstance(id: number, fields: any, hook: (schema) -> ()?): instance<shape>
		local states: { [number]: schema } = {}
		local dirty: { [number]: schema } = {}
		
		local instance = schemas.tree(shape, fields, function(schema)
			schema.updated:connect(function()
				dirty[schema.id] = schema
				dirtyInstances[id] = true
				local instance = instances[id]
				if instance then
					instance.markDirty:fire(schema)
				end
			end)
			states[schema.id] = schema
			if hook then
				hook(schema)
			end
		end) :: instance<shape>
		instance.id = id
		instance.markDirty = signal.new()
		
		instance.states = states
		instance.dirty = dirty
		
		factory.instanceAdded:fire(instance)
		instances[id] = instance
		newInstances[id] = instance
		return instance
	end
	
	function factory:instance(meta, fields)
		local groupInstancer = policy:instance(meta)
		local instance = createInstance(instanceId, fields, function(schema)
			local group = schema.group :: policyGroup<meta>? or policy.default
			local instancedGroup = groupInstancer(group)
			schema.group = instancedGroup
		end)
		dirtyInstances[instanceId] = true
		instanceId += 1
		
		function instance:commit(writer)
			local len = 0; for _ in instance.dirty do len += 1 end
			writer:u16(len)
			for id, schema in instance.dirty do
				writer:u16(id)
				schema:commit(writer)
			end
		end
		
		return instance
	end
	
	function factory:raw(override)
		local out: { [string]: any } = {}
		for key, schema in shape do
			out[key] = override[key] or schema.default
		end
		return out :: any
	end
	
	function factory:replicate(id: string)
		local numericId = transport.id(id)
		local route = transport.route(numericId)
		
		local awaitingSnapshots: { [transport.group]: true } = {}
		function route:commit(writer, group)
			if runService:IsServer() and group then
				local isSnapshot = awaitingSnapshots[group] ~= nil
				writer:bool(isSnapshot)
				if isSnapshot then
					local len = 0; for _ in instances do len += 1 end
					writer:u16(len)
					for _, instance: instance<shape> in instances do
						writer:u16(instance.id)
						struct.serialize(writer, instance:raw())
					end
					return
				else
					local len = 0; for _ in newInstances do len += 1 end
					writer:u16(len)
					for id in newInstances do
						writer:u16(id)
						local instance = instances[id]
						struct.serialize(writer, instance:raw())
					end
					
					local len = 0; for id in dirtyInstances do
						if newInstances[id] then
							continue
						end
						len += 1 
					end
					writer:u16(len)
					for id in dirtyInstances do
						if newInstances[id] then
							continue
						end
						writer:u16(id)
						local instance = instances[id]
						instance:commit(writer)
					end
				end
			end
		end
		
		local function newClientInstance(id, data)
			local instance = createInstance(id, data)
			function instance:consume(reader)
				for _ = 1, reader:u16() do
					local id = reader:u16()
					local schema = instance.states[id]
					if schema then
						schema:consume(reader)
					else
						print(instance, `Could not find state at id "{id}"`)
						error("CHECK PRINT ABOVE")
					end
				end
			end
			return instance
		end
		
		function route:consume(reader, context)
			if runService:IsServer() then
				local group = transport.group.static { context.player }
				awaitingSnapshots[group] = true
				route.markDirty:fire(group)
			else
				local isSnapshot = reader:bool()
				if isSnapshot then
					local snapshotCount = reader:u16()
					for _ = 1, snapshotCount do
						local id = reader:u16()
						local raw = struct.deserialize(reader)
						newClientInstance(id, raw)
					end
				else
					local len = reader:u16()
					for _ = 1, len do
						local id = reader:u16()
						newClientInstance(id, struct.deserialize(reader))
					end
					
					local len = reader:u16()
					for _ = 1, len do
						local id = reader:u16()
						local instance = instances[id]
						instance:consume(reader)
					end
				end
			end
		end
		
		transport.reliable:attach(route)
		if runService:IsServer() then
			factory.instanceAdded:connect(function(instance)
				instance.markDirty:connect(function(schema)
					route.markDirty:fire(schema.group)
				end)
			end)
		else
			route.markDirty:fire()
		end
		
		function route:clear()
			table.clear(awaitingSnapshots)
			for _, instance in instances do
				table.clear(instance.dirty)
			end
			table.clear(dirtyInstances)
			table.clear(newInstances)
		end
		
		return route
	end
	
	factory:index(struct)
	return factory
end


--// return
return schemas