package ratelimit

import (
	"context"
	"fmt"
	"time"

	"github.com/redis/go-redis/v9"
)

// tokenBucketScript implements a token bucket atomically inside Redis.
//
// Doing this in Lua rather than with GET/SET round trips matters: a
// read-modify-write from the client would let concurrent requests each read
// the same token count and all pass, which is exactly the burst an attacker
// needs.
//
// KEYS[1]   bucket key
// ARGV[1]   burst (bucket capacity)
// ARGV[2]   refill tokens per period
// ARGV[3]   period in milliseconds
// ARGV[4]   now in milliseconds
// ARGV[5]   requested cost
//
// Returns {allowed, remaining, retry_after_ms}.
const tokenBucketScript = `
local key     = KEYS[1]
local burst   = tonumber(ARGV[1])
local rate    = tonumber(ARGV[2])
local period  = tonumber(ARGV[3])
local now     = tonumber(ARGV[4])
local cost    = tonumber(ARGV[5])

local state   = redis.call('HMGET', key, 'tokens', 'ts')
local tokens  = tonumber(state[1])
local ts      = tonumber(state[2])

if tokens == nil then
  tokens = burst
  ts     = now
end

-- Refill for the time elapsed since the last request.
local elapsed = math.max(0, now - ts)
local refill  = elapsed * rate / period
tokens = math.min(burst, tokens + refill)

local allowed = 0
local retry   = 0

if tokens >= cost then
  tokens  = tokens - cost
  allowed = 1
else
  -- Time until enough tokens accumulate for this request.
  local deficit = cost - tokens
  retry = math.ceil(deficit * period / rate)
end

redis.call('HSET', key, 'tokens', tokens, 'ts', now)
-- Expire idle buckets so keys do not accumulate forever.
redis.call('PEXPIRE', key, math.ceil(period * (burst / rate) * 2))

return {allowed, math.floor(tokens), retry}
`

// RedisLimiter is a distributed token bucket.
type RedisLimiter struct {
	rdb    *redis.Client
	script *redis.Script
	prefix string
}

// NewRedisLimiter builds a limiter backed by the given Redis client.
func NewRedisLimiter(rdb *redis.Client) *RedisLimiter {
	return &RedisLimiter{
		rdb:    rdb,
		script: redis.NewScript(tokenBucketScript),
		prefix: "frogster:rl:",
	}
}

// Allow implements Limiter.
func (l *RedisLimiter) Allow(ctx context.Context, key string, rule Rule, cost int) (Decision, error) {
	now := time.Now().UnixMilli()
	res, err := l.script.Run(ctx, l.rdb,
		[]string{l.prefix + key},
		rule.Burst, rule.Rate, rule.Period.Milliseconds(), now, cost,
	).Slice()
	if err != nil {
		return Decision{}, fmt.Errorf("rate limit script: %w", err)
	}
	if len(res) != 3 {
		return Decision{}, fmt.Errorf("rate limit script returned %d values, want 3", len(res))
	}

	allowed, _ := res[0].(int64)
	remaining, _ := res[1].(int64)
	retryMS, _ := res[2].(int64)

	return Decision{
		Allowed:    allowed == 1,
		Remaining:  int(remaining),
		RetryAfter: time.Duration(retryMS) * time.Millisecond,
	}, nil
}
