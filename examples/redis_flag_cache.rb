# frozen_string_literal: true

# Redis-based distributed cache for PostHog feature flag definitions.
#
# This example demonstrates how to implement a FlagDefinitionCacheProvider
# using Redis for multi-instance deployments (leader election pattern).
#
# Usage:
#   require 'redis'
#   require 'posthog'
#   require_relative 'redis_flag_cache'
#
#   redis = Redis.new(host: 'localhost', port: 6379)
#   cache = RedisFlagCache.new(redis, service_key: 'my-service')
#
#   posthog = PostHog::Client.new(
#     api_key: '<project_api_key>',
#     personal_api_key: '<personal_api_key>',
#     flag_definition_cache_provider: cache
#   )
#
# Requirements:
#   gem install redis

require 'json'
require 'securerandom'

# A distributed cache for PostHog feature flag definitions using Redis.
#
# In a multi-instance deployment (e.g., multiple serverless functions or
# containers), we want only ONE instance to poll PostHog for flag updates,
# while all instances share the cached results. This prevents N instances
# from making N redundant API calls.
#
# Uses leader election:
# - One instance "wins" and becomes responsible for fetching
# - Other instances read from the shared cache
# - If the leader dies, the lock expires (TTL) and another instance takes over
#
# Uses Lua scripts for atomic operations, following Redis distributed lock
# best practices: https://redis.io/docs/latest/develop/clients/patterns/distributed-locks/
class RedisFlagCache
  LOCK_TTL_MS = 60 * 1000 # 60 seconds, should be longer than the flags poll interval
  CACHE_TTL_SECONDS = 60 * 60 * 24 # 24 hours

  # Lua script: acquire lock if free, or extend if we own it
  LUA_TRY_LEAD = <<~LUA
    local current = redis.call('GET', KEYS[1])
    if current == false then
      redis.call('SET', KEYS[1], ARGV[1], 'PX', ARGV[2])
      return 1
    elseif current == ARGV[1] then
      redis.call('PEXPIRE', KEYS[1], ARGV[2])
      return 1
    end
    return 0
  LUA

  # Lua script: release lock only if we own it
  LUA_STOP_LEAD = <<~LUA
    if redis.call('GET', KEYS[1]) == ARGV[1] then
      return redis.call('DEL', KEYS[1])
    end
    return 0
  LUA

  # @param redis [Redis] A redis client instance
  # @param service_key [String] Unique identifier for this service/environment,
  #   used to scope Redis keys. Examples: "my-api-prod", "checkout-service"
  #
  # Redis keys created:
  # - posthog:flags:{service_key} — cached flag definitions (JSON)
  # - posthog:flags:{service_key}:lock — leader election lock
  def initialize(redis, service_key:)
    @redis = redis
    @cache_key = "posthog:flags:#{service_key}"
    @lock_key = "posthog:flags:#{service_key}:lock"
    @instance_id = SecureRandom.uuid
  end

  # Retrieve cached flag definitions from Redis.
  #
  # @return [Hash, nil] Cached flag definitions, or nil if cache is empty
  def flag_definitions
    cached = @redis.get(@cache_key)
    return nil unless cached

    JSON.parse(cached)
  end

  # Determine if this instance should fetch flag definitions from PostHog.
  #
  # Atomically either acquires the lock (if free) or extends it (if we own it).
  #
  # @return [Boolean] true if this instance is the leader and should fetch
  def should_fetch_flag_definitions?
    result = @redis.eval(LUA_TRY_LEAD, keys: [@lock_key], argv: [@instance_id, LOCK_TTL_MS.to_s])
    result == 1
  end

  # Store fetched flag definitions in Redis.
  #
  # @param data [Hash] Flag definitions to cache
  def on_flag_definitions_received(data)
    @redis.set(@cache_key, JSON.dump(data), ex: CACHE_TTL_SECONDS)
  end

  # Release leadership if we hold it. Safe to call even if not the leader.
  def shutdown
    @redis.eval(LUA_STOP_LEAD, keys: [@lock_key], argv: [@instance_id])
  end
end
