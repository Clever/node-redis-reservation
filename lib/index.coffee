_     = require 'underscore'
os    = require 'os'
redis = require 'redis'
async = require 'async'
debug = require('debug') 'redis-reservation'
Resource = require './resource'

create_redis_client = _.memoize (host, port) ->
  redis.createClient port, host, { retry_max_delay:100, connect_timeout: 500, max_attempts: 10 }
, (host, port) -> "#{host}:#{port}"

module.exports = class ReserveManager
  constructor: (@by, @host, @port, @heartbeat_interval, @lock_ttl, @log=console.log) ->
    @_resources = []
    @_heartbeat = setInterval @_ensure_reservation, @heartbeat_interval
    @_heartbeat.unref() # Don't keep loop alive just for reservation

  create_resource: (resource) =>
    reserve_key = "reservation-#{resource}"
    reserve_val = "#{os.hostname()}-#{@by}-#{process.pid}"
    @_resources.push new Resource @_redis, reserve_key, reserve_val, @lock_ttl
    _(@_resources).last()

  lock: (resource, cb) =>
    @_init_redis()
    resource = @create_resource resource
    resource.lock @lock_ttl, (err, lock_status) =>
      if err
        @log "RESERVE: Failed to get lock for #{resource.reserve_key} on #{resource.reserve_val}"
        return cb err
      @log "RESERVE: #{resource.reserve_val} attempted to reserve #{resource.reserve_key}. STATUS: #{lock_status}"
      cb null, lock_status

  # Waits until a lock on the specific resource can be obtained
  wait_until_lock: (resource, cb) =>
    @_init_redis()
    resource_to_lock = @create_resource resource
    async.until(
      => resource_to_lock.locked
      (cb_u) =>
        resource_to_lock.lock @lock_ttl, (err, lock_status) =>
          @log "RESERVE: Attempted to reserve #{resource}:", lock_status, err
          setTimeout cb_u, 1000, err  # try every second
      (err) =>
        @log "RESERVE: Failed to reserve resource", err if err?
        @log "RESERVE: Done waiting for resource. reserve_state:", resource_to_lock.reserve_key
        cb err, resource_to_lock.locked
    )

  release: (cb) =>
    @_init_redis()
    clearInterval @_heartbeat if @_heartbeat? # We're done here, no more heartbeats
    async.each @_resources, (resource, cb_e) =>
      resource.release (err, state) =>
        if err
          @log "RESERVE: Failed to RELEASE LOCK for #{resource.reserve_key} on #{resource.reserve_val}"
        else
          @log 'RESERVE: Released', resource.reserve_key
        cb_e err
    , cb

  _ensure_reservation: =>
    async.each @_resources, (resource, cb_e) =>
      @log "#{resource.reserve_val} is extending reservation for #{resource.reserve_key}, by #{@lock_ttl}secs"
      resource.ensure (err) =>
        # Any errors from ensuring we still have the reservation should cause a graceful crash
        throw err if err
        resource.extend @lock_ttl, (err, expire_success) =>
          if err or not expire_success
            @log "RESERVE: Failed to ensure reservation, will try again in 10 minutes. expire_success:", expire_success, err
            cb_e()
    , (err) ->
      # Impossible for there to be an error here (either thrown or no error)

  _init_redis: =>
    # by default client tries to connect forever, fail after half a sec so worker can continue
    # will try again on next job
    return if @_redis
    @_redis = create_redis_client @host, @port
    @_redis.once 'error', (err) =>
      @log "RESERVE: Error connecting to REDIS: #{@host}:#{@port}.", err
      throw err
