_     = require 'underscore'
os    = require 'os'
redis = require 'redis'
async = require 'async'
debug = require('debug') 'redis-reservation'

create_redis_client = _.memoize (host, port, log) ->
  _redis = redis.createClient port, host,
    retry_max_delay: 100
    connect_timeout: 500
    max_attempts: 10
    socket_keepalive: true
  # Client emits an error every time it tries to reconnect and fails. Only emit an error once.
  _redis.once 'error', (err) ->
    log "RESERVE: Error connecting to REDIS: #{host}:#{port}.", err
    throw err
  _redis

, (host, port) -> "#{host}:#{port}"

module.exports = class ReserveResource
  constructor: (@by, @host, @port, @heartbeat_interval, @lock_ttl, @log=console.log) ->
    @_lost_reservation = false
    return

  lock: (resource, cb) ->
    @_init_redis()

    reserve_key = "reservation-#{resource}"
    val = "#{os.hostname()}-#{@by}-#{process.pid}"

    async.waterfall [
      (cb_wf) => @_redis.get reserve_key, (err, val) =>  # log existing value for runtime debugging
        @log "RESERVE: Existing resource lock value for", reserve_key, val unless err?  # ignore errors
        cb_wf()
      (cb_wf) => @_redis.set [reserve_key, val, 'EX', @lock_ttl, 'NX'], (err, state) =>
        debug "RESERVE: (err, state, reserve_key):", err, state, reserve_key
        if err?
          @log "RESERVE: Failed to get lock for #{reserve_key} on #{val}"
          return cb_wf err

        lock_status = if state? then (state is 1 or state is 'OK') else false
        @log("RESERVE:", val, "attempted to reserve", reserve_key, 'STATUS:', lock_status)
        return cb_wf err, false unless lock_status

        @_reserve_key = reserve_key
        @_reserve_val = val
        @_heartbeat = setInterval @_ensure_reservation.bind(@), @heartbeat_interval
        @_heartbeat.unref()  # don't keep loop alive just for reservation
        cb_wf err, lock_status
    ], cb

  wait_until_lock: (resource, cb) ->
    # waits until a lock on the specific resource can be obtained
    async.until(
      => @_reserve_key?
      (cb_u) => @lock resource, (err, lock_status) =>
        @log "RESERVE: Attempted to reserve #{resource}:", lock_status, err
        setTimeout cb_u, 1000, err  # try every second
      (err) =>
        @log "RESERVE: Failed to reserve resource", err if err?
        @log "RESERVE: Done waiting for resource. reserve_state:", @_reserve_key?
        return cb err, @_reserve_key?
    )

  release: (cb) ->
    return setImmediate cb unless @_reserve_key?  # nothing reserved here
    return setImmediate cb if @_lost_reservation

    clearInterval @_heartbeat if @_heartbeat? # we're done here, no more heartbeats
    @_init_redis()
    @_redis.del @_reserve_key, (err, state) =>
      @log "RESERVE: Failed to RELEASE LOCK for #{@_reserve_key} on #{@_reserve_val}" if err?
      @log 'RESERVE: Released', @_reserve_key unless err?
      delete @_reserve_key  # loose the lock
      delete @_reserve_val
      cb err, state or !err?

  _ensure_reservation: ->
    # make sure to hold the lock while running
    return unless @_reserve_key  # nothing reserved here
    @log "#{@_reserve_val} is extending reservation for #{@_reserve_key}, by #{@lock_ttl}secs"

    async.waterfall [
      (cb_wf) => @_redis.get @_reserve_key, cb_wf
      (reserved_by, cb_wf) =>
        unless reserved_by?  # we losts it
          @_lost_reservation = true
          throw new Error "Worker #{@_reserve_val} lost reservation for #{@_reserve_key}"
        unless reserved_by is @_reserve_val  # they stole the precious!!!
          @_lost_reservation = true
          throw new Error "Worker #{@_reserve_val} lost #{@_reserve_key} to #{reserved_by}"
        @_set_expiration cb_wf
    ], (err, expire_state) =>
      if err? or expire_state is 0
        @log "RESERVE: Failed to ensure reservation, will try again in 10 minutes. expire_status:", expire_state, err

  _set_expiration: (cb) ->
    return setImmediate cb unless @_reserve_key?  # nothing reserved here
    @_init_redis()

    # set expiration to lock_ttl
    @_redis.expire @_reserve_key, @lock_ttl, (err, state) =>
      @log "RESERVE: Failed to set expiration for #{@_reserve_key} after reservation", err if err?
      return cb null, (state is 1)

  _init_redis: ->
    @_redis = create_redis_client @host, @port, @log.bind(@) unless @_redis?
