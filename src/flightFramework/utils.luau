--!strict


--// types
export type stringDict = { [string]: any }


--// root
local utils = {}



-------------------------------------------------------
--// tables

function utils.combine<T1, T2>(t1: T1, t2: T2): T1 & T2
	local t1, t2 = t1 :: any, t2 :: any
	for k, v in t2 do
		t1[k] = t1[k] or v
	end
	return t1
end

local function clone(t: { [any]: any }, seen: { [any]: any })
	if type(t) ~= "table" then
		return t
	end
	
	if seen[t] then
		return seen[t]
	end

	local copy = {}
	seen[t] = copy

	for k, v in next, t do
		copy[k] = clone(v, seen)
	end

	return setmetatable(copy, getmetatable(t))
end

function utils.clone<T>(t: T): T
	if type(t) ~= "table" then
		return t
	end

	return clone(t, {})
end

-- determines if a table is empty
function utils.empty(t: { [any]: any }): boolean
	return next(t) == nil
end

function utils.length(t: { [any]: any }): number
	local length = 0
	for _ in t do
		length += 1
	end
	return length
end

function utils.ensurePath<T>(t: any, path: { any }, value: T): T
	local len = #path
	local current = t

	for i = 1, len do
		local key = path[i]

		local nextNode = current[key]
		if nextNode == nil then
			nextNode = (i == len) and value or {}
			current[key] = nextNode
		end

		current = nextNode
	end

	return current
end

function utils.setPath<T>(t: any, path: { any }, value: T)
	local len = #path
	local current = t

	for i = 1, len-1 do
		local key = path[i]

		local nextNode = current[key]
		if nextNode == nil then
			nextNode = {}
			current[key] = nextNode
		end

		current = nextNode
	end
	
	current[path[len]] = value
	return value
end


--// colors

function utils.multiplyColor(color: Color3, factor: number): Color3
	return Color3.new(
		color.R * factor,
		color.G * factor,
		color.B * factor
	)
end


-------------------------------------------------------
--// config


--// types
--functions
type function hasprop(ty: type, prop: string): type?
	if ty:is("table") then
		return types.singleton(ty:readproperty(types.singleton(prop)) ~= nil)
	elseif ty:is("intersection") or ty:is("union") then
		for _, component in ty:components() do
			local result = hasprop(component, prop)
			if result == true then
				return result
			end
		end
	end
	return nil
end

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
	end
	
	return ty
end

type function _gettypes(ty: type, optionalDefaults: type)
	local out = types.newtable()

	if ty:is("intersection") or ty:is("union") then
		for _, component in ty:components() do
			for key, prop in gettypes(component, optionalDefaults):properties() do
				out:setproperty(key, prop)
			end
		end
	elseif ty:is("table") then
		for key, prop in ty:properties() do
			local propType = prop.write or prop.read
			if propType then
				local inner = getinnerof(propType)
				if inner then
					local toset = inner
					if optionalDefaults:value() and not hasprop(propType, "default") then
						toset = types.optional(toset)
					end
					out:setproperty(key, toset)
				end
			end
		end
	end

	return out
end

export type gettypes<T, O> = _gettypes<T, O>

--native
type validator<T = any> = setmetatable<{
	__inner: T,
	errorMessage: string,
	validate: (any) -> T,
}, { __call: (any, T) -> validator<T> & { default: T } }>

utils.config = {}

local function wrap<T>(validator: (any) -> boolean, errorMessage: string): validator<T>
	return setmetatable({
		validate = validator,
		errorMessage = errorMessage
	}, { __call = function(self, default)
		self.default = default
		return self
	end })
end


utils.config.wrap = wrap

---------------
--// primitives

function utils.config.is<T>(typeName: string)
	return utils.config.wrap<<T>>(function(value)
		return typeof(value) == typeName
	end, `expected <{typeName}>, got <%s>`)
end


utils.config.number  = utils.config.is <<number>> "number"
utils.config.string  = utils.config.is <<string>> "string"
utils.config.boolean = utils.config.is <<boolean>> "boolean"

---------------
--// slightly complex

function utils.config.enum<T>(values: T)
	local values = values :: { string }

	return utils.config.wrap<<keyof<T>>>(function(value)
		return values[value] ~= nil
	end, `%s is not a valid enum`)
end

function utils.config.optional<T>(validator: T)
	local validator = validator :: validator
	return utils.config.wrap<<getinnerof<T>>>(function(value)
		return value == nil or validator.validate(value)
	end, `{validator.errorMessage} — additionally: optional validation failed`)
end


-------------------------------------------------------
--// config construction

function utils.config.new<shape>(shape: shape)
	local shape = shape :: any
	return setmetatable({
		input  = (nil :: any) :: gettypes<shape, true>,
		resolved = (nil :: any) :: gettypes<shape, false>
	}, { __call = function(_, fields: gettypes<shape, true>): gettypes<shape, false>
		local fields = fields :: { [string]: any }
		local reconciled = {}

		for field: string, validator: validator & { default: any? } in shape do
			local default = validator.default

			local value = fields[field] ~= nil and fields[field] or validator.default
			assert(validator.validate(value), validator.errorMessage:format(typeof(value)))

			reconciled[field] = value
		end
		
		for field in fields do
			assert(shape[field], `Unknown config field "{field}"`)
		end

		return table.freeze(reconciled) :: any
	end })
end


-------------------------------------------------------
--// index

type validIndexer = { [any]: any } | (any, any) -> any?
export type wrapped<T = any> = T & { index: (self: wrapped<T>, ...any) -> () -> () }

function utils.index<T>(t: T): wrapped<T>
	local t = t :: wrapped<T>

	local index: { [validIndexer]: true } = {}
	function t:index(...)
		local args = table.pack(...)
		for _, indexer in next, {...} do
			if indexer then
				index[indexer] = true
			end
		end
		return function()
			for _, indexer in table.unpack(args) do
				index[indexer] = nil
			end
		end
	end

	local mt = getmetatable(t) or {} :: any
	mt.__index = function(self, k)
		for indexer in index do
			local result
			if type(indexer) == "table" then
				result = indexer[k]
			else
				result = indexer(self, k)
			end
			if result then return result end
		end
	end
	setmetatable(t :: any, mt)

	return t
end



--// return
return utils