_               = require 'underscore'
redis           = require 'redis'
assert          = require 'assert'
async           = require 'async'
domain          = require 'domain'
debug           = require('debug') 'test/redis-reservation'
ReserveResource = require "#{__dirname}/../lib/index"

class BaseWorker
  constructor: (payload, @cb) ->
    worker_domain = domain.create()
    worker_domain.on 'error', (err) ->
      console.log "FAILED: Exception caught by domain:", err.stack
      worker_domain.dispose()
    worker_domain.once 'error', (err) => @_complete err  # only call complete once
    @reservation = new ReserveResource @constructor._name,
      process.env.REDIS_HOST,
      process.env.REDIS_PORT,
      @_hearbeat_interval,
      @_lock_ttl
    setImmediate =>
      worker_domain.enter()
      @_run payload, (args...) =>
        worker_domain.exit()
        @_complete args...
  _complete: (args...) ->
    @reservation.release (err) =>
      console.log "ENDING #{@constructor._name} WORKER with args:", args
      @cb args...
  _run: (payload, cb) -> cb new Error "must implement _run"
  _hearbeat_interval: 10*60*1000  # 10 minutes in milliseconds for resource reservation
  _lock_ttl: 30*60  # 30 minutes in seconds for resource reservation

class LockWorker extends BaseWorker
  @_name: 'test_worker'
  _run: (payload, cb) ->
    console.log "running test_worker"
    console.log "RESERVE", @reserve
    @reservation.lock payload.resource_id, (err, state) ->
      return cb "no_reservations" unless state
      return cb null, "whostheboss.iam"

class PasswordWorker extends BaseWorker
  @_name: 'redis_password_worker'
  _run: (payload, cb) ->
    console.log "running redis_password_worker"
    console.log "RESERVE", @reserve
    @reservation.password = payload.password
    @reservation.lock payload.resource_id, (err, state) ->
      return cb "no_reservations" unless state
      return cb null, "whostheboss.iam"

class FreeWorker extends BaseWorker
  @_name: 'free_worker'
  _run: (payload, cb) ->
    cb null, "always_done"

class FailWorker extends BaseWorker
  @_name: 'fail_worker'
  _run: (payload, cb) ->
    throw new Error(":(")

class SlowWorker extends BaseWorker
  @_name: 'slow_worker'
  _hearbeat_interval: 500
  _lock_ttl: 1
  _run: (payload, cb) ->
    console.log "running slow_worker"
    @reservation.lock payload.resource_id, (err, state) ->
      setTimeout((state) ->
        return cb "no_reservations" unless state
        return cb null, "whostheboss.iam"
      , 2000
      , state)

class WaitWorker extends BaseWorker
  @_name: 'wait_worker'
  _hearbeat_interval: 500
  _lock_ttl: 1
  _run: (payload, cb) ->
    console.log "running wait_worker"
    @reservation.wait_until_lock payload.resource_id, (err, state) ->
      return cb "no_reservations" unless state
      return cb null, 'patience_is_bitter_but_fruit_is_sweet'

describe 'ReserveResource', ->
  it "allows you to create a bunch of reservations", ->
    # Reasons it might fail:
    #  * memory leaks
    #  * connection limits
    for i in [0...10000000]
      resource = new ReserveResource 'some worker', process.env.REDIS_HOST, process.env.REDIS_PORT
      resource._init_redis()

describe 'redis-reservation', ->

  before (done) ->
    @redis = redis.createClient(process.env.REDIS_PORT, process.env.REDIS_HOST)
    #@redis.select 3
    done()

  beforeEach (done) ->
    @redis.flushall done

  it 'can reserve and release a lock', (done) ->
    test_worker = new LockWorker resource_id: 'test_resource', (err, resp) =>
      assert.equal null, err
      assert.equal resp, 'whostheboss.iam'
      @redis.get 'reservation-test_resource', (err, resp) ->
        assert.equal resp, null
        done()

  it 'can reserve and release a lock with redis password', (done) ->
    @redis.config 'set', 'requirepass', '12345'
    @redis.auth '12345'

    payload = resource_id: 'test_resource', password: '12345'
    test_worker = new PasswordWorker payload, (err, resp) =>
      @redis.config 'set', 'requirepass', ''

      assert.equal null, err
      assert.equal resp, 'whostheboss.iam'
      @redis.get 'reservation-test_resource', (err, resp) ->
        assert.equal resp, null
        done()

  it 'holds a lock while running', (done) ->
    test_worker = new SlowWorker resource_id: 'test_resource', (err, resp) =>
      assert.equal null, err
      assert.equal resp, 'whostheboss.iam'
      @redis.get 'resource-test_resource', (err, resp) ->
        assert.equal resp, null
        done()

  it 'can wait for a lock', (done) ->
    setTimeout(=>
      @redis.del 'reservation-test_resource', -> return
    , 1000)

    @redis.set 'reservation-test_resource', 'MOCK', (err, resp) =>
      test_worker = new WaitWorker resource_id: 'test_resource', (err, resp) =>
        assert.equal null, err
        assert.equal resp, 'patience_is_bitter_but_fruit_is_sweet'
        @redis.get 'reservation-test_resource', (err, resp) ->
          assert.equal resp, null
          done()

  it 'fails silently if resource is already reserved', (done) ->
    @redis.set 'reservation-test_resource', 'MOCK', (err, resp) =>
      test_worker = new LockWorker resource_id: 'test_resource', (err, resp) =>
        assert.equal err, 'no_reservations'
        @redis.get 'reservation-test_resource', (err, resp) ->
          assert.equal resp, 'MOCK'
          done()

  it 'does not interfere for workers without reservations', (done) ->
    @redis.set 'reservation-test_resource', 'MOCK', (err, resp) =>
      test_worker = new FreeWorker resource_id: 'test_resource', (err, resp) =>
        assert.equal resp, 'always_done'
        @redis.get 'reservation-test_resource', (err, resp) ->
          assert.equal resp, 'MOCK'
          done()

  it 'handles failing jobs', (done) ->
    @redis.set 'reservation-test_resource', 'MOCK', (err, resp) =>
      test_worker = new FailWorker resource_id: 'test_resource', (err, resp) =>
        assert.equal err.message, ":("
        assert.equal null, resp
        @redis.get 'reservation-test_resource', (err, resp) ->
          assert.equal resp, 'MOCK'
          done()

  it 'fails on no redis', (done) ->
    process.env.REDIS_HOST = 'localhost'
    process.env.REDIS_PORT = 6666  # incorrect port
    test_worker = new SlowWorker resource_id: 'test_resource', (err, resp) ->
      console.log "ERR", err
      assert.equal err.message, "Redis connection to localhost:6666 failed - connect ECONNREFUSED"
      setTimeout done, 1000
