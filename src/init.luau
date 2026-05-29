--[=[
	To work like value objects in Roblox and track a single item,
	with `.Changed` events
	@class ValueObject
]=]

const ReplicatedStorage = game:GetService('ReplicatedStorage')
const require = require(ReplicatedStorage.Packages.Loader).load()

const Brio = require('Brio')
const DuckTypeUtils = require('DuckTypeUtils')
const Maid = require('Maid')
const MaidTaskUtils = require('MaidTaskUtils')
const Observable = require('Observable')
const RxValueBaseUtils = require('RxValueBaseUtils')
const Signal = require('Signal')

-- selene: allow(unused_variable)
const Rx = require("Rx")
const Subscription = require("Subscription")

const ValueBaseUtils = require('ValueBaseUtils')

const EMPTY_FUNCTION = function() end

const ValueObject = {}
ValueObject.ClassName = 'ValueObject'

export type TypeChecker = (value: any) -> (boolean, string?)
export type ValueObjectTypeArg = string | TypeChecker
export type Mountable<T> = T | Observable.Observable<T> | ValueBase | ValueObject<T>
export type ValueObject<T> = typeof(setmetatable(
	{} :: {
		--[=[
			The value of the ValueObject
			@prop Value T
			@within ValueObject
		]=]
		Value: T,

		--[=[
			Event fires when the value's object value change
			@prop Changed Signal<T> -- fires with oldValue, newValue, ...
			@within ValueObject
		]=]
		Changed: Signal.Signal<(T, T, ...any)>,
		LastEventContext: { any },

		_checkType: ValueObjectTypeArg?,
		_value: T,
		_default: T?,
		_lastEventContext: { any }?,
		_lastMountedSub: Subscription.Subscription<(T, ...any)>?,
	},
	{} :: typeof({ __index = ValueObject })
))

--[=[
	Constructs a new value object
	@param baseValue T
	@param checkType string? | (value: T) -> (boolean, string?)
	@return ValueObject
]=]
@checked
function ValueObject.new<T>(baseValue: T?, checkType: ValueObjectTypeArg?): ValueObject<T>
	const self: ValueObject<T> = setmetatable(
		{
			_value = baseValue,
			_default = baseValue,
			_checkType = checkType,
		} :: any,
		ValueObject
	)

	if type(checkType) == 'string' then
		if typeof(baseValue) ~= checkType then
			error(
				string.format(
					'Expected value of type %q, got %q instead',
					checkType,
					typeof(baseValue)
				)
			)
		end
	elseif type(checkType) == 'function' then
		assert(checkType(baseValue))
	end

	return self
end

--[=[
	Returns the current check type, if any

	@return string? | (value: T) -> (boolean, string)
]=]
@checked
function ValueObject.GetCheckType<T>(self: ValueObject<T>): ValueObjectTypeArg?
	return rawget(self :: any, '_checkType')
end

--[=[
	Constructs a new value object
	@param observable Observable<T>
	@return ValueObject<T>
]=]
@checked
function ValueObject.fromObservable<T>(observable: Observable.Observable<T>): ValueObject<T>
	const result = ValueObject.new()

	result:Mount(observable)

	return result
end

--[=[
	Returns whether the object is a ValueObject class
	@param value any
	@return boolean
]=]
@checked
function ValueObject.isValueObject(value: any): boolean
	return DuckTypeUtils.isImplementation(ValueObject, value)
end

@checked
function ValueObject._toMountableObservable<T>(
	_self: ValueObject<T>,
	value: Mountable<T>
): Observable.Observable<T>?
	if Observable.isObservable(value) then
		return value :: any
	elseif typeof(value) == 'Instance' then
		-- IntValue, ObjectValue, et cetera
		if ValueBaseUtils.isValueBase(value) then
			return RxValueBaseUtils.observeValue(value)
		end
	elseif type(value) == 'table' then
		if ValueObject.isValueObject(value) then
			return (value :: any):Observe()
			-- elseif Promise.isPromise(value) then
			-- 	return Rx.fromPromise(value)
		end
	end

	return nil
end

--[=[
	Mounts the value to the observable. Overrides the last mount.

	@param value Observable | T
	@return MaidTask
]=]
@checked
function ValueObject.Mount<T>(self: ValueObject<T>, value: Mountable<T>): () -> ()
	const observable = self:_toMountableObservable(value)
	if observable then
		self:_cleanupLastMountedSub()

		const sub = observable:Subscribe(function(...)
			ValueObject._applyValue(self, ...)
		end)

		rawset(self :: any, '_lastMountedSub', sub)

		return function()
			if rawget(self :: any, '_lastMountedSub') == sub then
				self:_cleanupLastMountedSub()
			end
		end
	else
		self:_cleanupLastMountedSub()

		ValueObject._applyValue(self, value :: T)

		return EMPTY_FUNCTION
	end
end

@checked
function ValueObject._cleanupLastMountedSub<T>(self: ValueObject<T>)
	const lastSub = rawget(self :: any, '_lastMountedSub')
	if lastSub then
		rawset(self :: any, '_lastMountedSub', nil)
		MaidTaskUtils.doTask(lastSub)
	end
end

--[=[
	Observes the current value of the ValueObject
	@return Observable<T?>
]=]
@checked
function ValueObject.Observe<T>(self: ValueObject<T>): Observable.Observable<T>
	const found = rawget(self :: any, '_observable')
	if found then
		return found
	end

	const created = Observable.new(function(sub)
		if not self.Destroy then
			warn('[ValueObject.observeValue] - Connecting to dead ValueObject')
			-- No firing, we're dead
			sub:Complete()
			return
		end

		const connection = self.Changed:Connect(function(newValue, _, ...)
			sub:Fire(newValue, ...)
		end)

		const args = rawget(self :: any, '_lastEventContext')
		const value = rawget(self :: any, '_value')
		if args then
			sub:Fire(value, table.unpack(args, 1, args.n))
		else
			sub:Fire(value)
		end

		return connection
	end)

	-- We use a lot of these so let's cache the result which reduces the number of tables we have here
	rawset(self :: any, '_observable', created)
	return created :: any
end

--[=[
	Observes the value as a brio. The condition defaults to truthy or nil.

	@param condition function | nil -- optional
	@return Observable<Brio<T>>
]=]
@checked
function ValueObject.ObserveBrio<T>(
	self: ValueObject<T>,
	condition: Rx.Predicate<T>?
): Observable.Observable<Brio.Brio<T>>
	assert(type(condition) == 'function' or condition == nil, 'Bad condition')

	return Observable.new(function(sub)
		if not self.Destroy then
			warn('[ValueObject.observeValue] - Connecting to dead ValueObject')
			-- No firing, we're dead
			sub:Complete()
			return
		end

		const maid = Maid.new()

		const handleNewValue = function(newValue: T, ...)
			if not condition or condition(newValue) then
				const brio = Brio.new(newValue, ...)
				maid._current = brio
				sub:Fire(brio)
			else
				maid._current = nil
			end
		end

		maid:GiveTask(self.Changed:Connect(function(newValue, _previous, ...)
			handleNewValue(newValue, ...)
		end))

		const args = rawget(self :: any, '_lastEventContext')
		if args then
			handleNewValue(self.Value, table.unpack(args, 1, args.n))
		else
			handleNewValue(self.Value)
		end

		return maid
	end) :: any
end

--[=[
	Allows you to set a value, and provide additional event context for the actual change.
	For example, you might do.

	```lua
	self.IsVisible:SetValue(isVisible, true)

	print(self.IsVisible.Changed:Connect(function(isVisible, _, doNotAnimate)
		print(doNotAnimate)
	end))
	```

	@param value T
	@param ... any -- Additional args. Can be used to pass event changing state args with value
	@return () -> () -- Cleanup
]=]
@checked
function ValueObject.SetValue<T>(self: ValueObject<T>, value: T, ...)
	self:_cleanupLastMountedSub()

	ValueObject._applyValue(self, value, ...)

	return function()
		if rawget(self :: any, '_value') == value then
			ValueObject._applyValue(self, rawget(self :: any, '_default') :: any)
		end
	end
end

--[=[
	Gets the value and then the additional args from the last event
]=]
@checked
function ValueObject.GetValue<T>(self: ValueObject<T>): (T, ...any)
	const value: T = rawget(self :: any, '_value') :: any
	const args = rawget(self :: any, '_lastEventContext')

	if args then
		return value, table.unpack(args, 1, args.n)
	else
		return value
	end
end

@checked
function ValueObject._applyValue<T>(self: ValueObject<T>, value: T, ...)
	const previous = rawget(self :: any, '_value')
	const checkType = rawget(self :: any, '_checkType')

	if type(checkType) == 'string' then
		if typeof(value) ~= checkType then
			error(
				string.format(
					'Expected value of type %q, got %q instead',
					checkType,
					typeof(value)
				)
			)
		end
	elseif typeof(checkType) == 'function' then
		assert(checkType(value))
	end

	if previous ~= value then
		if select('#', ...) > 0 then
			rawset(self :: any, '_lastEventContext', table.pack(...))
		else
			rawset(self :: any, '_lastEventContext', nil)
		end

		rawset(self :: any, '_value', value)
		const changed = rawget(self :: any, 'Changed')
		if changed then
			changed:Fire(value, previous, ...)
		end
	end
end

@checked
function ValueObject:__index(index)
	if ValueObject[index] then
		return ValueObject[index]
	elseif index == 'Value' then
		return rawget(self :: any, '_value')
	elseif index == 'Changed' then
		-- Defer construction of Changed event until something needs it, since a lot
		-- of times we don't need it

		const signal = Signal.new() -- :Fire(newValue, oldValue, ...)

		rawset(self :: any, 'Changed', signal)

		return signal
	elseif index == 'LastEventContext' then
		const args = rawget(self :: any, '_lastEventContext')
		if args then
			return table.unpack(args, 1, args.n)
		else
			return
		end
	elseif index == '_value' then
		return nil -- Edge case
	else
		error(string.format('%q is not a member of ValueObject', tostring(index)))
	end
end

@checked
function ValueObject:__newindex(index, value)
	if index == 'Value' then
		-- Avoid deoptimization
		ValueObject._applyValue(self, value)
	elseif index == 'LastEventContext' or ValueObject[index] then
		error(string.format('%q cannot be set in ValueObject', tostring(index)))
	else
		error(string.format('%q is not a member of ValueObject', tostring(index)))
	end
end

--[=[
	Forces the value to be nil on cleanup, cleans up the Maid

	Does not fire the event since 3.5.0
]=]
@checked
function ValueObject.Destroy<T>(self: ValueObject<T>)
	rawset(self :: any, '_value', nil)

	self:_cleanupLastMountedSub()

	-- Avoid using a maid here because we make a LOT of ValueObjects
	const changed = rawget(self :: any, 'Changed')
	if changed then
		changed:Destroy()
	end

	setmetatable(self :: any, nil)
end

return ValueObject
