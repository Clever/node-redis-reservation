node-redis-reservation
======================

redis reservations are like locks/mutexes except they can expire.

### constructor(by, host, port, heartbeat_interval, lock_ttl, log, password)

Creates a new redis-reservation which includes setting up redis connection credentials.

##### Arguments
- `by` - The worker name
- `host` - Redis host to connect to
- `port` - Redis port to connect to
- `heartbeat_interval` - Renew the lock at every `heartbeat_interval` milliseconds
- `lock_ttl` - Renew the lock for `lock_ttl` seconds
- `log` - Log to use or else defaults to console.log
- `password` - Password to authenticate with redis server

##### Example
```
ReserveResource = require 'redis-reservation'

reservation = new ReserveResource
  'worker-name',
  process.env.REDIS_HOST,
  process.env.REDIS_PORT,
  10 * 60 * 1000,           # 10 minutes
  30 * 60                   # 30 minutes
  # log,                     # defaults to console.log
  # password                # defaults to no password (empty string)
```

----
### lock(resource, callback)

Attempts to lock the resource if it can.

##### Arguments
- `resource` - The key to use to uniquely identify this lock
- `callback(err, lock_status)` - `lock_status` is `true` if lock was acquired, `false` otherwise.

##### Example
```
reservation.lock job_name, (err, lock_status) ->
  return err if err?
  if lock_status
    do_job()
  else
    console.log 'Reservation already held'
```

----
### wait_until_lock(resource, callback)
Waits until the lock can be acquired for the resource.

##### Arguments
- `resource` - The key to use to uniquely identify this lock
- `callback(err, reserve_key)` - `callback` is called only when the lock can be acquired. `reserve_key` is the name of the key in redis that was used to acquire the lock.

##### Example
```
reservation.wait_until_lock job_name, (err, reserve_key) ->
  return err if err?
  do_job()
```

----
### release(callback)
Releases the lock.

##### Arguments
- `callback(err)` - Callback to be called once the lock is released, or error.

##### Example
```
reservation.release (err) ->
  if err?
    console.log 'Could not release lock, maybe the reservation was already lost?'
  return err
```
test
