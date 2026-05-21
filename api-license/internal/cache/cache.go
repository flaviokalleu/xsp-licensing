package cache

import (
	"context"
	"errors"
	"time"

	"github.com/redis/go-redis/v9"
)

type Cache struct {
	rdb *redis.Client
}

func New(url string) (*Cache, error) {
	opt, err := redis.ParseURL(url)
	if err != nil {
		return nil, err
	}
	rdb := redis.NewClient(opt)
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	if err := rdb.Ping(ctx).Err(); err != nil {
		return nil, err
	}
	return &Cache{rdb: rdb}, nil
}

// RememberNonce stores nonce for TTL; returns ErrReplay if already used.
var ErrReplay = errors.New("nonce already used")

func (c *Cache) RememberNonce(ctx context.Context, nonce string, ttl time.Duration) error {
	ok, err := c.rdb.SetNX(ctx, "n:"+nonce, "1", ttl).Result()
	if err != nil {
		return err
	}
	if !ok {
		return ErrReplay
	}
	return nil
}

// RateLimit using sliding window via INCR + EXPIRE.
func (c *Cache) RateLimit(ctx context.Context, key string, max int, window time.Duration) (bool, error) {
	n, err := c.rdb.Incr(ctx, "rl:"+key).Result()
	if err != nil {
		return false, err
	}
	if n == 1 {
		c.rdb.Expire(ctx, "rl:"+key, window)
	}
	return n <= int64(max), nil
}
