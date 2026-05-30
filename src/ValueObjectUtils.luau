
--[=[
	Utils that work with Roblox Value objects (and also ValueObject)
	@class ValueObjectUtils
]=]

const Brio = require('./roblox_packages/Brio')
const Maid = require('./roblox_packages/Maid')
const Observable = require('./roblox_packages/Observable')
const ValueObject = require('.')

const ValueObjectUtils = {}

--[=[
	Syncs the value from `from` to `to`.
	@param from ValueObject<T>
	@param to ValueObject<T>
	@return MaidTask
]=]
@checked
function ValueObjectUtils.syncValue<T>(from: ValueObject.ValueObject<T>, to: ValueObject.ValueObject<T>): Maid.Maid
	const maid = Maid.new()
	to.Value = from.Value

	maid:GiveTask(from.Changed:Connect(function()
		to.Value = from.Value
	end))

	return maid
end

--[=[
	Observes the current value of the ValueObject

	@deprecated 13.18.0
	@param valueObject ValueObject<T>
	@return Observable<T>
]=]
@checked
function ValueObjectUtils.observeValue<T>(valueObject: ValueObject.ValueObject<T>): Observable.Observable<T>
	assert(ValueObject.isValueObject(valueObject), 'Bad valueObject')

	return valueObject:Observe()
end

--[=[
	Observes the current value of the ValueObject
	@param valueObject ValueObject<T>
	@return Observable<Brio<T>>
]=]
@checked
function ValueObjectUtils.observeValueBrio<T>(valueObject: ValueObject.ValueObject<T>): Observable.Observable<Brio.Brio<T>>
	assert(valueObject, 'Bad valueObject')

	return Observable.new(function(sub)
		const maid = Maid.new()

		const function refire()
			const brio = Brio.new(valueObject.Value)
			maid._lastBrio = brio
			sub:Fire(brio)
		end

		maid:GiveTask(valueObject.Changed:Connect(refire))

		refire()

		return maid
	end) :: any
end

return ValueObjectUtils
