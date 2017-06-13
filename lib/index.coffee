_      = require 'underscore'
os     = require 'os'
redis  = require 'redis'
async  = require 'async'
kayvee = require 'kayvee'

create_redis_client = _.memoize (host, port, password, logger) ->
  _redis = redis.createClient port, host,
    retry_max_delay: 100
    connect_timeout: 500
    max_attempts: 10
    socket_keepalive: true

  _redis.auth password if password

  # Client emits an error every time it tries to reconnect and fails. Only emit an error once.
  _redis.once 'error', (err) ->
    logger.errorD "redis-error", { host, port, err }
    throw err
  _redis

, (host, port, password) -> "#{host}:#{port}:#{password}"

module.exports = class ReserveResource
  constructor: (@by, @host, @port, @heartbeat_interval, @lock_ttl, @password='') ->
    @_lost_reservation = false
    @identifer = process.env.JOB_ID or process.pid
    @logger = new kayvee.logger(@by)
    @logger.globals.job_id = process.env.JOB_ID
    @logger.globals.via = "node-redis-reservation"
    return

  lock: (system_id, cb) ->
    @_init_redis()

    reserve_key = "reservation-#{system_id}"
    val = "#{@by}-#{@identifer}"

    async.waterfall [
      (cb_wf) => @_redis.get reserve_key, (err, val) =>  # log existing value for runtime debugging
        @logger.infoD "reservation-existing", { key: reserve_key, system_id } unless err?
        cb_wf()
      (cb_wf) => @_redis.set [reserve_key, val, 'EX', @lock_ttl, 'NX'], (err, state) =>
        if err?
          @logger.infoD "reservation-failed", { system_id, key: reserve_key }
          return cb_wf err

        lock_status = if state? then (state is 1 or state is 'OK') else false
        @logger.infoD "reservation-attempted", { system_id, lock_status, key: reserve_key }
        return cb_wf err, false unless lock_status

        @_reserve_key = reserve_key
        @_reserve_val = val
        @_heartbeat = setInterval @_ensure_reservation.bind(@), @heartbeat_interval
        @_heartbeat.unref()  # don't keep loop alive just for reservation
        cb_wf err, lock_status
    ], cb

  wait_until_lock: (system_id, cb) ->
    # waits until a lock on the specific system_id can be obtained
    async.until(
      => @_reserve_key?
      (cb_u) => @lock system_id, (err, lock_status) =>
        @logger.infoD "reservation-attempt", { system_id, lock_status }
        setTimeout cb_u, 1000, err  # try every second
      (err) =>
        @logger.errorD "reservation-failed", { system_id, err, val } if err?
        @logger.infoD "reservation-acquired", { system_id, key: @_reserve_key }
        return cb err, @_reserve_key?
    )

  release: (cb) ->
    return setImmediate cb unless @_reserve_key?  # nothing reserved here
    return setImmediate cb if @_lost_reservation

    clearInterval @_heartbeat if @_heartbeat? # we're done here, no more heartbeats
    @_init_redis()
    @_redis.del @_reserve_key, (err, state) =>
      @logger.errorD "reservation-release-failed", { key: @_reserve_key, val: @_reserve_val } if err?
      @logger.infoD "reservation-released", { key: @_reserve_key } unless err?
      delete @_reserve_key  # lose the lock
      delete @_reserve_val
      cb err, state or !err?

  _ensure_reservation: -> @ensure_reservation()
  # If ensure_reservation is called without a callback (e.g. when we run it on an interval, in the
  # background), it throws any errors that receives. Otherwise, it passes them to the callback.
  ensure_reservation: (cb) ->
    cb ?= (err) -> throw err if err?
    # make sure to hold the lock while running
    return unless @_reserve_key  # nothing reserved here
    @logger.infoD "reservation-extended", { key: @_reserve_key, duration: "#{@lock_ttl}s", val: @_reserve_val }
    async.waterfall [
      (cb_wf) => @_redis.get @_reserve_key, cb_wf
      (reserved_by, cb_wf) =>
        unless reserved_by?  # we losts it
          @_lost_reservation = true
          return cb_wf new Error "Worker #{@_reserve_val} lost reservation for #{@_reserve_key}"
        unless reserved_by is @_reserve_val  # they stole the precious!!!
          @_lost_reservation = true
          return cb_wf new Error "Worker #{@_reserve_val} lost #{@_reserve_key} to #{reserved_by}"
        @_set_expiration cb_wf
    ], (err, expire_state) =>
      return cb err if err
      if expire_state is 0
        return cb new Error "RESERVE: Failed to ensure reservation. expire_status:", expire_state
      cb()

  _set_expiration: (cb) ->
    return setImmediate cb unless @_reserve_key?  # nothing reserved here
    @_init_redis()

    # set expiration to lock_ttl
    @_redis.expire @_reserve_key, @lock_ttl, (err, state) =>
      @logger.errorD "expire-set-failed", { err, key: @_reserve_key } if err?
      return cb null, (state is 1)

  _init_redis: ->
    @_redis = create_redis_client @host, @port, @password, @logger unless @_redis?
