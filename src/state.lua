--[[description:

	- state defines the reactive runtime used throughout the framework
	- states represent live, mutable data with dependency tracking
	- states automatically track relationships between:
		- values: mutable pieces of data
		- containers: collections of child states
		- derived values: derived data based on other states
		- reacts: reactions that run when dependencies change
	
	- dependencies are created automatically through state reads
	- updates only affect observers connected to changed data

]]
--!strict


--// services
local replicatedStorage = game:GetService("ReplicatedStorage")


--// modules
local modules = replicatedStorage.modules
local cleaner = require(modules.cleaner)
local signal = require(modules.signal)
local utils = require(modules.utils)


--// validators
--imported
type signal<P... = ...any> = signal.signal<P...>

--native
export type source = {
	version: number,
	value: any,
	observers: { [observer]: true },
	onChange: (any, any) -> ()?,
	destroyed: boolean,
}

export type typedSource<T = any> = {
	__inner: T,
	changed: signal<T, T>, -- new, old
	peek: (self: typedSource<T>) -> T,
	get: (self: typedSource<T>) -> T,
	invalidate: (self: typedSource<T>) -> (),
}

export type observer = {
	kind: "derived" | "react",
	tracker: () -> any?,
	sources: { [source]: number },
	depth: number,
	dirty: boolean,
	refreshing: boolean,
	destroyed: boolean,
	
	isderived: (self: observer) -> boolean,
	destroy: (self: observer) -> ()
}

export type observerSource = observer & source

--// root
local state = {}


-------------------------------------------------------
--// observer tracking
--[[

	- manages the internal dependency tracking system
	- observers subscribe to states when they read from them
	- dependencies are discovered automatically during execution
	
	- observers maintain relationships with the states they depend on
	- these relationships determine which observers update when state changes
	
]]

local currentObserver: observer?
local currentThread: thread?

local function beginTracking(observer: observer)
	local prevObserver = currentObserver
	local prevThread = currentThread
	currentObserver = observer
	currentThread = coroutine.running()
	return prevObserver, prevThread
end

local function endTracking(prevObserver: observer?, prevThread: thread?)
	currentObserver = prevObserver
	currentThread = prevThread
end


-------------------------------------------------------
--// flushing
--[[

	- manages the execution of pending observer updates
	
	- changes to state mark dependent observers as needing updates
	- flushing resolves these pending updates in the correct order
	
	- derived values update before reacts that depend on them
	- updates are batched together to avoid unnecessary recomputation

]]

local pendingreacts: { [react]: true } = {}
local isFlushing = false
local transactionDepth = 0
local MAX_FLUSH_ITERATION = 100 -- just a safe guard. ridiculously unlikely

local function notifyObservers(observers: { [observer]: true })
	local queue = {} :: { observer }
	for observer in observers do
		table.insert(queue, observer)
	end

	local i = 1
	while i <= #queue do
		local observer = queue[i]
		i += 1
		if observer.destroyed then
			continue
		end

		if observer.kind == "react" then
			pendingreacts[observer] = true
		elseif observer.kind == "derived" and not observer.dirty then
			observer.dirty = true
			for source in (observer :: observerSource).observers do
				table.insert(queue, source)
			end
		end
	end
end

local function runObserver(observer: observer): any
	if observer.destroyed then
		return
	end

	local prevSources = observer.sources
	observer.sources = {}
	observer.refreshing = true

	local prevObserver, prevThread = beginTracking(observer)
	local ok, result = pcall(observer.tracker)
	endTracking(prevObserver, prevThread)

	observer.refreshing = false

	if ok then
		local newSources = observer.sources
		for source in prevSources do
			if not newSources[source] then
				source.observers[observer] = nil
			end
		end
	else
		warn(result :: string, debug.traceback(nil, 2))
		for source, sourceVersion in prevSources do
			if not observer.sources[source] and not source.destroyed then
				observer.sources[source] = sourceVersion
				source.observers[observer] = true
			end
		end
		result = if observer.kind == "derived" then (observer :: observerSource).value else nil
	end

	local maxDepth = 0
	for source in observer.sources do
		local d = (source :: any).depth
		if d and d > maxDepth then
			maxDepth = d
		end
	end
	observer.depth = maxDepth + 1
	observer.dirty = false

	return result
end

local function refreshderived(observer: observerSource)
	local new = runObserver(observer)
	local changed = new ~= observer.value
	
	if changed then
		observer.value = new
		observer.version += 1
	end
	
	observer.dirty = false
	
	if changed then
		notifyObservers(observer.observers)
	end
end

local function isStale(observer: observer): boolean
	for source, sourceVersion in observer.sources do
		local maybederived = source :: any
		if maybederived.kind == "derived" then
			local derived = maybederived :: observerSource
			if derived.dirty then
				refreshderived(derived)
			end
		end

		if source.version ~= sourceVersion then
			return true
		end
	end

	return false
end

local function flush()
	if isFlushing then
		return
	end
	isFlushing = true

	local iterations = 0
	while next(pendingreacts) do
		if iterations > MAX_FLUSH_ITERATION then
			warn("Exceeded max iteration limited")
			table.clear(pendingreacts)
			break
		end

		local batch = {} :: { observer }
		for observer in pendingreacts do
			table.insert(batch, observer)
			pendingreacts[observer] = nil
		end
		table.sort(batch, function(a: observer, b: observer)
			return a.depth < b.depth
		end)

		for _, react in batch do
			if not react.destroyed and isStale(react) then
				runObserver(react)
			end
		end
	end

	isFlushing = false
end


-------------------------------------------------------
--// sources
--[[
	
	- defines the primitive reactive data source used by the state system
	
	- sources store:
		- current value
		- change version
		- subscribed observers
	
	- reading a source creates a dependency
	- writing a source notifies dependent observers
	
	- this section provides the foundation for reactivity
	
]]

local function newSource(value: any): source
	return {
		value = value,
		version = 0,
		observers = {},
		destroyed = false
	} :: any
end

local function readSource(source: source)
	assert(not source.destroyed, "Attempt to read destroyed source")

	-- checks for current observer
	-- if it exists, the source declares itself a source that the observer is watching
	if currentObserver then
		currentObserver.sources[source] = source.version
		source.observers[currentObserver] = true
	end

	return source.value
end

local function invalidateSource(source: source)
	assert(not source.destroyed, "Attempt to invalidate a destroyed source")
	
	source.version += 1
	notifyObservers(source.observers)
	
	if transactionDepth == 0 then
		flush()
	end
end

local function writeSource(source: source, value: any)
	assert(not source.destroyed, "Attempt to write to a destroyed source")

	local prev = source.value
	if prev == value then
		return
	end

	source.value = value

	if source.onChange then
		source.onChange(value, prev)
	end

	-- invalidate the source upon update so that watching observers know to update
	invalidateSource(source)
end


-------------------------------------------------------
--// value state
--[[
	
	- provides the primary interface for managing individual pieces of state
	
	- value states wrap primitive data with:
		- reactive reads
		- validated writes
		- change signals
		- lifecycle management
	
	- value states are the simplest form of managed state
	
]]

export type value<T = any> = typedSource<T> & {
	source: source,
	
	set: (self: value<T>, T) -> boolean,
	update: (self: value<T>, (T) -> T) -> T?,
	
	validator: (self: value<T>, (T, T) -> boolean) -> () -> (),
	destroy: (self: value<T>) -> ()
}

function state.value<T>(initial: T?): value<T>
	local source = newSource(initial)
	local alive = true
	
	
	-- state object
	local value = {
		source = source,
		changed = signal.new()
	} :: value<T>
	
	source.onChange = function(new, old)
		value.changed:fire(new, old)
	end
	
	
	-- validation
	local validators: { [(T, T) -> boolean]: true } = {}
	local function validate(new, old)
		for validator in validators do
			if not validator(new, old) then
				return false
			end
		end
		return true
	end
	
	function value:validator(predicate: (T, T) -> boolean)
		validators[predicate] = true
		return function()
			validators[predicate] = nil
		end
	end
	
	value.changed:once(function(new)
		if new then
			-- only initial type allowed
			local valueType = typeof(new)
			value:validator(function(new)
				return typeof(new) == valueType
			end)
		end
	end)
	value.changed:fire(initial, nil)
	
	
	-- reading + writing
	
	function value:peek()
		assert(alive, `value state is destroyed`)
		return source.value
	end
	
	function value:get()
		assert(alive, `value state is destroyed`)
		return readSource(source)
	end
	
	function value:set(value)
		assert(alive, `value state is destroyed`)
		if validate(value, source.value) then
			writeSource(source, value)
			return true
		end
		return false
	end
	
	function value:update(updater: (T) -> T)
		assert(alive, `value state is destroyed`)
		local updated = updater(source.value)
		return value:set(updated) and updated or nil
	end
	
	function value:invalidate()
		invalidateSource(source)
	end
	
	function value:destroy()
		assert(alive, `value state is destroyed`)

		alive = false
		source.destroyed = true
		source.version += 1
		source.onChange = nil
		table.clear(source.observers)
		table.clear(validators)
		
		if transactionDepth == 0 then
			flush()
		end
	end
	
	
	return value
end


-------------------------------------------------------
--// containers
--[[
	
	- provides reactive collections of dynamically keyed child values
	
	- containers support:
		- adding and removing children
		- observing individual child changes
		- observing collection-wide changes
	
	- each child maintains its own reactive dependency relationship
	- the collection itself can also be observed as a whole
	
]]

export type container<K = any, V = any> = {
	cleaner: cleaner.cleaner,
	
	childChanged: signal<K, V, V>,
	childAdded: signal<K, V>,
	childRemoved: signal<K, V>,
	
	length: value<number>,
	children: value<{ [K]: V }>,
	
	peek: (self: container<K, V>, K) -> V,
	get: (self: container<K, V>, K) -> V,
	set: (self: container<K, V>, K, V?) -> boolean,
	
	find: (self: container<K, V>, V) -> K?,
	each: (self: container<K, V>, (K, V) -> () -> ()) -> () -> (),
	-- returns a deterministic iterator over the container's key/value pairs
	-- iteration order is defined by the container's comparator
	iter: typeof(function(self: container<K, V>, untrack: boolean?): () -> (K, V) return nil::any end),
	
	validator: (self: container<K, V>, (K, V, V) -> boolean) -> () -> (),
	destroy: (self: container<K, V>) -> (),
}

type containerOptions<K, V> = {
	comparator: (K, V, K, V) -> boolean
}

local function sortable(v: any) local t = typeof(v) return t == "string" or t == "number" end
function state.container<K, V>(options: containerOptions<K, V>?): container<K, V>
	local options = options or {
		comparator = function(k1, v1, k2, v2)
			assert(sortable(k1) and sortable(k2))
			return k1 < k2
		end,
	}
	
	local container = {
		cleaner = cleaner.new(),
		
		childChanged = signal.new(),
		childAdded = signal.new(),
		childRemoved = signal.new(),
		
		length = state.value(0),
		children = state.value({})
	} :: container
	
	
	-- validation
	local validators: { [(...any) -> boolean]: true } = {}
	local function validate(key, new, old)
		for validator in validators do
			if not validator(key, new, old) then
				return false
			end
		end
		return true
	end

	function container:validator(predicate: (...any) -> boolean)
		validators[predicate] = true
		return function()
			validators[predicate] = nil
		end
	end

	container.childChanged:once(function(key, new)
		if new then
			-- only initial type allowed
			local keyType = typeof(key)
			local valueType = typeof(new)
			container:validator(function(key, new)
				return typeof(key) == keyType and typeof(new) == valueType
			end)
		end
	end)
	
	-- container object
	function container:peek(key)
		return container.children:peek()[key]
	end
	
	local sources: { [any]: source } = {}
	local function getSource(key: any)
		local source = sources[key]
		if not source then
			source = newSource(nil)
			sources[key] = source
		end
		return source
	end
	
	function container:get(key)
		local source = getSource(key)
		return readSource(source)
	end
	
	function container:find(target)
		for key, value in self.children:peek() do
			if value == target then
				return key
			end
		end
		return nil
	end
	
	function container:each(callback)
		local cleaner = self.cleaner:scope()
		local cleanups = {}
		
		local function register(key, value)
			local cleanup = callback(key, value)
			cleanups[key] = cleanup
		end
		
		cleaner:give(self.childChanged:connect(function(key, new, old)
			if old ~= nil then
				local cleanup = cleanups[key]
				cleanups[key] = nil

				if cleanup then
					cleanup()
				end
			end
			
			if new ~= nil then
				register(key, new)
			end
		end))
		
		for key, value in self:iter() do
			register(key, value)
		end
		
		return function()
			for _, cleanup in cleanups do
				cleanup()
			end
			cleaner:destroy()
		end
	end
	
	function container:iter(untrack)
		local children = self.children[untrack and "peek" or "get"](self.children)
		
		local keys, i = {}, 1
		for key in children do
			keys[i] = key
			i += 1
		end
		
		table.sort(keys, function(a: string, b: string)
			return options.comparator(a, children[a], b, children[b])
		end)
		
		local n = 0
		return function()
			n += 1
			
			local key = keys[n]
			if key then
				return key, children[key]
			end
		end
	end
	
	-- handle added and removing signals
	container.childChanged:connect(function(index, new, old)
		if new and not old then
			container.childAdded:fire(index, new)
		elseif not new and old then
			container.childRemoved:fire(index, old)
		end
	end)
	
	function container:set(key, value)
		return state.transaction(function()
			return container.children:update(function(children): any?
				local old = children[key]
				
				if not validate(key, value, old) then
					return nil
				end
				
				children[key] = value
				invalidateSource(container.children.source)

				-- update child source
				local source = getSource(key)
				writeSource(source, value)
				if value == nil then
					source.value = nil
					source.version += 1
				end

				container.childChanged:fire(key, value, old)

				-- update length
				if old == nil and value ~= nil then
					container.length:update(function(n) return n + 1 end)
				elseif old ~= nil and value == nil then
					container.length:update(function(n) return n - 1 end)
				end

				return children
			end) ~= nil
		end)
	end
		
	
	return container
end


-------------------------------------------------------
--// observers
--[[
	
	- defines reactive computations that respond to state changes
	
	- observers track the states they read during execution
	- future changes to those states determine when they run again
	
	- observers are divided into:
		- derived values: cached derived state
		- reacts: side reacts triggered by state changes
	
	- this section manages reactive execution
	- it does not define the data being observed
	
]]

local function newObserver(tracker: () -> any?): observer
	return {
		tracker = tracker,
		sources = {},
		depth = 1,
		dirty = true,
		refreshing = false,
		destroyed = false,
	} :: any
end

export type derived<T> = observerSource & typedSource<T>

function state.derived<T>(tracker: () -> T): derived<T>
	local observer = newObserver(tracker) :: derived<T>
	observer.kind = "derived"
	observer = utils.combine(observer, newSource(nil))
	
	function observer:get()
		if observer.destroyed then
			error("Observer is destroyed")
		end

		if observer.dirty then
			refreshderived(observer)
		end

		if currentObserver and coroutine.running() == currentThread then
			currentObserver.sources[observer :: any] = observer.version
			observer.observers[currentObserver] = true
		end

		return observer.value :: T
	end

	function observer:isderived()
		return true
	end

	function observer:destroy()
		if observer.destroyed then
			error("Observer is destroyed")
		end
		observer.destroyed = true
		observer.version += 1
		for source in observer.sources do
			source.observers[observer] = nil
		end
		table.clear(observer.sources)
		table.clear(observer.observers)
	end
	
	return observer
end

export type react = observer

function state.react(tracker: () -> ()): react
	local observer = newObserver(tracker)
	observer.kind = "react"
	runObserver(observer)
	
	function observer:destroy()
		if observer.destroyed then
			error("Observer is destroyed")
		end
		observer.destroyed = true
		pendingreacts[observer] = nil
		for source in observer.sources do
			source.observers[observer] = nil
		end
		table.clear(observer.sources)
	end
	
	return observer
end


-------------------------------------------------------
--// transactions
--[[
	
	- provides batched state updates
	- changes inside a transaction delay observer execution until the transaction completes
	
	- nested transactions are combined into a single update cycle
	- this reduces unnecessary recomputation during multiple related writes
	
	- transactions batch updates, but do not provide rollback or persistence guarantees

]]

function state.transaction<T>(fn: () -> T?): T
	transactionDepth += 1
	local ok, result = pcall(fn)
	transactionDepth -= 1
	if transactionDepth == 0 and ok then
		flush()
	end
	
	if not ok then
		error(result, 2)
	end
	
	return result
end


-------------------------------------------------------
--// untracking

function state.untrack<T>(fn: () -> T): T
	local prevObserver = currentObserver
	local prevThread = currentThread

	currentObserver = nil
	currentThread = nil

	local ok, result = pcall(fn)

	currentObserver = prevObserver
	currentThread = prevThread

	if not ok then
		error(result, 2)
	end

	return result
end


--// return
return state