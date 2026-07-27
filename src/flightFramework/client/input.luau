--overview: input handler for ffv1
--v1.0.0
--[[description:

	overview //
		1. define contexts which are ordered
		2. create input sources (actions / axes / pointers) from that context
		3. bind keys or inputs to sources
		4. connect listeners to the sources
	
	-------------------------------------------------------
	
	input flow //
		1. Roblox input is received via ContextActionService
		2. If input is not fired through CAS, then UserInputService dispatches the input
		3. loops through contexts from top to bottom
		4. loops from bindings from top to bottom
		5. checks the dispatchResult of dispatched bindings for sinking policy
		
	input sources //
		- actions: button-like input (press/release, like jump or shoot)
		- axis2: directional or continuous movement (like WASD or a thumbstick)
		- pointer: mouse/touch interaction (position, clicks, mouse movement)
		
	dispatchResults //
		- pass: ignore the input and let it continue to lower bindings/contexts
		- consume: handle the input and stop it from going to lower contexts
		- sink: completely block the input so nothing else (including Roblox) receives it

]]
--!strict


--// services
local contextActionService = game:GetService("ContextActionService")
local players = game:GetService("Players")
local replicatedStorage = game:GetService("ReplicatedStorage")
local runService = game:GetService("RunService")
local userInputService = game:GetService("UserInputService")


--// client references
local player = players.LocalPlayer :: Player
local _, playerModule = pcall(require, (player.PlayerScripts :: any):WaitForChild("PlayerModule"))
local playerControls = playerModule:GetControls() :: { GetMoveVector: (self: any) -> Vector3 }


--// root
local inputHandler = {
	pass = { result = "pass" },
	consume = { result = "consume" },
	sink = { result = "sink" }
}

local contextMap = {} :: { [string]: context }
local contextList = {} :: { _head: context?, _tail: context? }


--// types
--dispatcher
export type connection<P... = ()> = {
	connected: boolean,
	_fn: (P...) -> dispatchResult,
	
	_next: connection<P...>?,
	_prev: connection<P...>?,
	
	disconnect: (self: connection<P...>) -> (),
}

export type dispatcher<P... = ()> = {
	_head: connection<P...>?,
	_tail: connection<P...>?,
	
	connect: (self: dispatcher<P...>, callback: (P...) -> dispatchResult) -> connection<P...>,
	dispatch: (self: dispatcher<P...>, P...) -> dispatchResult
}

--input
export type dispatchResult = typeof(inputHandler.pass) | typeof(inputHandler.consume) | typeof(inputHandler.sink)

export type binding = {
	_next: binding?,
	_prev: binding?,
	
	matches: (self: binding, input: InputObject) -> boolean,
	dispatch: (self: binding, input: InputObject) -> dispatchResult,
	
	unbind: (self: binding) -> (),
}

type orderable<T> = {
	_next: orderable<T>,
	_prev: orderable<T>,
	
	_priority: number,
	
	insertAbove: (self: orderable<T>, T) -> orderable<T>,
	insertBelow: (self: orderable<T>, T) -> orderable<T>,
	insertWithPriority: (self: orderable<T>, number) -> orderable<T>
}

export type action = {
	context: context,
	
	bindKeys: (self: action, ...Enum.KeyCode) -> binding,
	bindInputTypes: (self: action, ...Enum.UserInputType) -> binding,
	
	pressed: dispatcher,
	released: dispatcher
}

export type axis2 = {
	context: context,

	_value: Vector2,
	_delta: Vector2,

	bindKeys: (self: axis2, keys: {
		up: Enum.KeyCode,
		down: Enum.KeyCode,
		left: Enum.KeyCode,
		right: Enum.KeyCode
	}) -> binding,
	bindThumbstick: (self: axis2) -> binding,
	bindMouseDelta: (self: axis2) -> binding,
	bindMobileThumbstick: (self: axis2) -> binding,
	
	changed: dispatcher<Vector2>,
	deltaChanged: dispatcher<Vector2>
}

export type pointerEvent = {
	pointer: pointer,
	pointerId: number,

	inputObject: InputObject,
	inputType: Enum.UserInputType,

	position: Vector2,
	delta: Vector2,
}

export type pointer = {
	context: context,

	began: dispatcher<pointerEvent>,
	changed: dispatcher<pointerEvent>,
	ended: dispatcher<pointerEvent>,

	_positions: { [number]: Vector2 },
	_down: { [number]: boolean },

	getPosition: (self: pointer, pointerId: number) -> Vector2?,
	isDown: (self: pointer, pointerId: number) -> boolean
}

export type context = {
	_enabled: boolean,
	
	enable: (self: context) -> context,
	disable: (self: context) -> context,
	isEnabled: (self: context) -> boolean,
	
	_next: context?,
	_prev: context?,
	_head: binding?,
	_tail: binding?,
	
	insertAbove: (self: context, context: context | string) -> context,
	insertBelow: (self: context, context: context | string) -> context,
	
	action: (self: context) -> action,
	axis2: (self: context) -> axis2,
	pointer: (self: context) -> pointer
}


--// linked lists

local function insertIntoList<T>(list: any, element: any, before: any)
	if not list._head then
		list._head = element
		list._tail = element
	else
		if not before then
			-- generic insert at tail
			local tail = list._tail
			if tail then
				tail._next = element
			end
			element._prev = tail
			element._next = nil :: any
			list._tail = element
			
		else
			-- we are inserting before 'before', meaning it is a higher priority
			local beforeBefore = before._prev
			if beforeBefore then
				beforeBefore._next = element
			else
				list._head = element
			end
			element._prev = beforeBefore
			element._next = before
			before._prev = element
		end
	end
end

local function removeFromList<T>(list: any, element: any)
	-- remove from neighbors
	local nextElement, prevElement = element._next, element._prev
	
	if nextElement then
		nextElement._prev = prevElement
	end
	if prevElement then
		prevElement._next = nextElement
	end
	
	-- remove from list
	if list._head == element then
		list._head = nextElement :: any
	end
	if list._tail == element then
		list._tail = prevElement :: any
	end
	
	-- remove neighbors from self
	element._next = nil :: any
	element._prev = nil :: any
end


--// dispatcher api
local dispatcherClass = {} :: dispatcher & { __index: dispatcher }
dispatcherClass.__index = dispatcherClass

local function newDispatcher(): dispatcher
	return setmetatable({} :: dispatcher, dispatcherClass)
end

function dispatcherClass:connect(callback)
	local dispatcher = self
	
	local connection = {
		connected = true,
		_fn = callback
	} :: connection
	
	insertIntoList(dispatcher, connection)
	
	function connection:disconnect()
		if not self.connected then return end
		self.connected = false
		
		removeFromList(dispatcher, connection)
	end
	
	return connection
end

function dispatcherClass:dispatch(...)
	local connection = self._head
	while connection do
		local nextConn = connection._next
		
		if connection.connected then
			local result = connection._fn(...) or inputHandler.pass
			if result ~= inputHandler.pass then
				return result
			end
		end
		
		connection = nextConn
	end
	
	return inputHandler.pass
end


--// binding api

local function newBinding(context: context): binding
	local binding = {} :: binding
	
	insertIntoList(context, binding)
	
	function binding:unbind()
		removeFromList(context, binding)
		table.clear(binding)
	end
	
	return binding
end


--// action api
local actionClass = {} :: action & { __index: action }
actionClass.__index = actionClass

local function newAction(context: context): action
	local action = setmetatable({
		context = context,
		pressed = newDispatcher(),
		released = newDispatcher()
	} :: action, actionClass)
	
	return action
end

local function bindActionInput(action: action, inputType: string, ...)
	local map = {}
	for _, inputType in {...} do
		map[inputType] = true
	end
	
	local binding = newBinding(action.context)
	
	function binding:matches(input)
		return map[(input :: any)[inputType]] ~= nil
	end
	
	function binding:dispatch(input)
		if input.UserInputState == Enum.UserInputState.Begin then
			return action.pressed:dispatch()
		elseif input.UserInputState == Enum.UserInputState.End then
			return action.released:dispatch()
		end
		return inputHandler.pass
	end
	
	return binding
end

function actionClass:bindKeys(...)
	return bindActionInput(self, "KeyCode", ...)
end

function actionClass:bindInputTypes(...)
	return bindActionInput(self, "UserInputType", ...)
end


--// axis2 api
local axis2Class = {} :: axis2 & { __index: axis2 }
axis2Class.__index = axis2Class

local function newAxis2(context: context): axis2
	return setmetatable({
		context = context,
		_value = Vector2.zero,
		_delta = Vector2.zero,
		changed = newDispatcher(),
		deltaChanged = newDispatcher()
	} :: axis2, axis2Class)
end

local function recomputeAxis2(axis2: axis2): dispatchResult
	local value = axis2._value
	
	if value.Magnitude > 1 then
		value = value.Unit
		axis2._value = value
	end
	
	return axis2.changed:dispatch(value)
end

function axis2Class:bindKeys(keys)
	local binding = newBinding(self.context)
	
	local state = {
		up = false,
		down = false,
		left = false,
		right = false
	}

	local function recompute()
		local x, y = 0, 0
		
		if state.up then y += 1 end
		if state.down then y -= 1 end
		if state.left then x -= 1 end
		if state.right then x += 1 end
		
		local value = Vector2.new(x, y)
		self._value = value
		return recomputeAxis2(self)
	end

	function binding:matches(input)
		for dir, key in keys :: any do
			if key == input.KeyCode then
				return true
			end
		end
		return false
	end
	
	function binding:dispatch(input)
		for dir, key in keys :: any do
			if key == input.KeyCode then
				state[dir] = input.UserInputState == Enum.UserInputState.Begin
			end
		end
		return recompute()
	end
	
	return binding
end

function axis2Class:bindThumbstick(thumbstick)
	local axis2 = self

	local binding = newBinding(self.context)

	function binding:matches(input)
		return input.KeyCode == thumbstick
	end

	function binding:dispatch(input)
		local pos = input.Position
		axis2._value = Vector2.new(pos.X, pos.Y)

		if math.abs(axis2._value.X) < 0.1 then
			axis2._value = Vector2.new(0, axis2._value.Y)
		end
		if math.abs(axis2._value.Y) < 0.1 then
			axis2._value = Vector2.new(axis2._value.X, 0)
		end

		return recomputeAxis2(axis2)
	end

	return binding
end

function axis2Class:bindMouseDelta()
	local axis2 = self

	local binding = newBinding(self.context)

	function binding:matches(input)
		return input.UserInputType == Enum.UserInputType.MouseMovement
	end

	function binding:dispatch(input)
		local delta = userInputService:GetMouseDelta()
		axis2._delta += delta
		return axis2.deltaChanged:dispatch(delta)
	end

	return binding
end

function axis2Class:bindMobileThumbstick()
	local axis2 = self
	local binding = newBinding(self.context)

	function binding:matches()
		return false
	end

	runService.RenderStepped:Connect(function()
		local value = playerControls:GetMoveVector()
		value = Vector2.new(value.X, -value.Z)
		axis2._value = value
		recomputeAxis2(axis2)
	end)

	return binding
end


--// pointer api
local pointerClass = {} :: pointer & { __index: pointer }
pointerClass.__index = pointerClass

local nextTouchPointerId = 1
local touchPointerIds = {} :: { [InputObject]: number }

local function getPointerId(input: InputObject): number
	if input.UserInputType ~= Enum.UserInputType.Touch then
		return 0
	end
	
	local pointerId = touchPointerIds[input]
	if not pointerId then
		pointerId = nextTouchPointerId
		nextTouchPointerId += 1
		touchPointerIds[input] = pointerId
	end
	
	return pointerId
end

local function releasePointeId(input: InputObject)
	if input.UserInputType == Enum.UserInputType.Touch then
		touchPointerIds[input] = nil
	end
end

local function newPointer(context: context): pointer
	local pointer = setmetatable({
		context = context,
		began = newDispatcher(),
		changed = newDispatcher(),
		ended = newDispatcher(),
		_positions = {},
		_down = {},
	} :: pointer, pointerClass)

	local binding = newBinding(context)

	function binding:matches(input)
		return input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.MouseButton2
			or input.UserInputType == Enum.UserInputType.Touch
			or input.UserInputType == Enum.UserInputType.MouseMovement
	end

	function binding:dispatch(input)
		local pointerId = getPointerId(input)

		local oldPosition = pointer._positions[pointerId]
		local position = Vector2.new(input.Position.X, input.Position.Y)
		local delta = oldPosition and position - oldPosition or Vector2.zero

		pointer._positions[pointerId] = position

		local event: pointerEvent = {
			pointer = pointer,
			pointerId = pointerId,
			position = position,
			delta = delta,
			inputObject = input,
			inputType = input.UserInputType,
		}

		if input.UserInputState == Enum.UserInputState.Begin then
			pointer._down[pointerId] = true
			return pointer.began:dispatch(event)
		elseif input.UserInputState == Enum.UserInputState.Change then
			return pointer.changed:dispatch(event)
		elseif input.UserInputState == Enum.UserInputState.End then
			pointer._down[pointerId] = nil
			local result = pointer.ended:dispatch(event)
			pointer._positions[pointerId] = nil
			releasePointeId(input)
			return result
		end

		return inputHandler.pass
	end

	return pointer
end

function pointerClass:getPosition(pointerId)
	return self._positions[pointerId]
end

function pointerClass:isDown(pointerId)
	return self._down[pointerId] ~= nil
end


--// context api
local contextClass = {} :: context & { __index: context }
contextClass.__index = contextClass

local function newContext(name: string?): context
	local context = setmetatable({
		_enabled = true
	} :: context, contextClass)
	
	insertIntoList(contextList, context)
	
	if name then
		contextMap[name] = context
	end
	
	return context
end

local function dispatchToContext(context: context, input: InputObject): dispatchResult
	local binding = context._head
	while binding do
		local nextBinding = binding._next
		
		if binding:matches(input) then
			local ok, result = pcall(binding.dispatch, binding, input)
			if not ok then
				warn(result)
			end
			if result ~= inputHandler.pass then
				return result
			end
		end
		
		binding = nextBinding
	end
	
	return inputHandler.pass
end

local function getContext(context: context | string): context?
	if type(context) == "string" then
		return contextMap[context]
	end
	
	return context
end

function contextClass:insertAbove(context)
	local context = getContext(context)
	assert(context ~= nil, `Could not find context "{context}"`)
	
	removeFromList(contextList, self)
	insertIntoList(contextList, self, context)
	
	return self
end

function contextClass:insertBelow(context)
	local context = getContext(context)
	assert(context ~= nil, `Could not find context "{context}"`)
	
	removeFromList(contextList, self)
	insertIntoList(contextList, self, context._next)
	
	return self
end


--inputSource apis
function contextClass:action()
	return newAction(self)
end

function contextClass:axis2()
	return newAxis2(self)
end

function contextClass:pointer()
	return newPointer(self)
end


--controls
function contextClass:enable()
	self._enabled = true
	return self
end

function contextClass:disable()
	self._enabled = false
	return self
end

function contextClass:isEnabled()
	return self._enabled
end


--// public api
inputHandler.context = newContext
inputHandler.dispatcher = newDispatcher

function inputHandler.mouseVector(): Vector2
	return userInputService:GetMouseLocation()
end

function inputHandler.topContext(): context?
	return contextList._head
end

function inputHandler.handleResult(priorResult: dispatchResult, result: dispatchResult): dispatchResult
	if result == inputHandler.sink then
		return result
	elseif result == inputHandler.consume then
		return result
	end
	
	return priorResult
end


--// input routing
local inputProcessed = false

local function dispatchInput(_, _, input: InputObject): Enum.ContextActionResult
	inputProcessed = true
	
	local context = contextList._head
	while context do
		local belowContext = context._next
		
		if context._enabled then
			local result = dispatchToContext(context, input)
			if result ~= inputHandler.pass then
				if result == inputHandler.sink then
					return Enum.ContextActionResult.Sink
				end
				return Enum.ContextActionResult.Pass
			end
		end
		
		context = belowContext
	end
	
	return Enum.ContextActionResult.Pass
end

contextActionService:BindAction("root", dispatchInput, false, table.unpack(Enum.UserInputType:GetEnumItems()))

local function uisInput(input: InputObject)
	if not inputProcessed then
		dispatchInput(nil, nil, input)
	end
	inputProcessed = false
end

userInputService.InputBegan:Connect(uisInput)
userInputService.InputChanged:Connect(uisInput)
userInputService.InputEnded:Connect(uisInput)


--// return
return inputHandler