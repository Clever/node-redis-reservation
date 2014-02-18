#!/usr/bin/env bash

# drone runs tests in a container w/ a linked mongodb container
# docker has its own convention around env vars for linked containers
# translate that env into what our tests expect
npm install
REDIS_HOST=$REDIS_PORT_6379_TCP_ADDR REDIS_PORT=$REDIS_PORT_6379_TCP_PORT npm test
