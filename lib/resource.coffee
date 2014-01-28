_ = require 'underscore'
async = require 'async'

# node-redis, y u no consistent in return values??
redis_truthy = (val) -> val in [1, 'OK', true]

module.exports = class Resource
  constructor: (@redis, @reserve_key, @reserve_val, time) ->
    @locked = false
  lock: (time, cb) =>
    @redis.set [@reserve_key, @reserve_val, 'EX', time, 'NX'], (err, state) =>
      return cb err if err
      return cb null, false unless redis_truthy state
      @locked = true
      cb null, true
  release: (cb) =>
    return setImmediate cb unless @locked
    @redis.del @reserve_key, (err, state) =>
      return cb err if err
      # What do we do if state isn't redis_truthy?
      @locked = false
      cb err, redis_truthy state
  ensure: (cb) =>
    return setImmediate cb unless @locked
    async.waterfall [
      (cb_wf) => @redis.get @reserve_key, cb_wf
      (reserved_by, cb_wf) =>
        # Async releases the zalgo :(
        cb_wf = _(cb_wf).wrap (fn, args...) -> setImmediate fn, args...
        unless reserved_by?  # we losts it
          cb_wf new Error "Worker #{@reserve_val} lost reservation for #{@reserve_key}"
        unless reserved_by is @reserve_val  # they stole the precious!!!
          cb_wf new Error "Worker #{@reserve_val} lost #{@reserve_key} to #{reserved_by}"
        cb_wf()
    ], (err) =>
      @locked = false if err
      cb err
  extend: (time, cb) =>
    return setImmediate cb unless @locked
    @redis.expire @reserve_key, time, (err, state) =>
      return cb err if err
      cb null, redis_truthy state
