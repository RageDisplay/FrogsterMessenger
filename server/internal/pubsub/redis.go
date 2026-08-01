package pubsub

import (
	"context"
	"fmt"
	"log/slog"
	"sync"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
)

const channelPrefix = "frogster:user:"

// RedisBroker fans out through Redis pub/sub.
//
// It subscribes per connected user rather than to one global channel, so an
// instance only receives traffic for users it actually holds sockets for.
// A single firehose would make every instance decode every message in the
// cluster.
type RedisBroker struct {
	rdb    *redis.Client
	pubsub *redis.PubSub
	out    chan []byte

	mu    sync.Mutex
	users map[uuid.UUID]int // refcount: a user may have several local devices

	log    *slog.Logger
	cancel context.CancelFunc
	wg     sync.WaitGroup
}

// NewRedisBroker starts a broker and its receive loop.
func NewRedisBroker(ctx context.Context, rdb *redis.Client, log *slog.Logger) *RedisBroker {
	runCtx, cancel := context.WithCancel(ctx)

	b := &RedisBroker{
		rdb: rdb,
		// Subscribing with no channels yields a PubSub that channels can be
		// added to later.
		pubsub: rdb.Subscribe(runCtx),
		out:    make(chan []byte, 256),
		users:  make(map[uuid.UUID]int),
		log:    log,
		cancel: cancel,
	}

	b.wg.Add(1)
	go b.receive(runCtx)
	return b
}

func (b *RedisBroker) receive(ctx context.Context) {
	defer b.wg.Done()
	ch := b.pubsub.Channel()

	for {
		select {
		case <-ctx.Done():
			return
		case msg, ok := <-ch:
			if !ok {
				return
			}
			select {
			case b.out <- []byte(msg.Payload):
			case <-ctx.Done():
				return
			default:
				// Dropping here is safe: the message is already persisted in
				// the offline queue, so the recipient gets it on reconnect.
				b.log.Warn("pubsub output buffer full, dropping frame")
			}
		}
	}
}

// Publish implements Broker.
func (b *RedisBroker) Publish(ctx context.Context, userID uuid.UUID, payload []byte) error {
	if err := b.rdb.Publish(ctx, channelPrefix+userID.String(), payload).Err(); err != nil {
		return fmt.Errorf("publish to user channel: %w", err)
	}
	return nil
}

// Subscribe implements Broker, refcounting so several devices of one user on
// this instance share a single subscription.
func (b *RedisBroker) Subscribe(ctx context.Context, userID uuid.UUID) error {
	b.mu.Lock()
	defer b.mu.Unlock()

	if b.users[userID]++; b.users[userID] > 1 {
		return nil
	}
	if err := b.pubsub.Subscribe(ctx, channelPrefix+userID.String()); err != nil {
		b.users[userID]--
		return fmt.Errorf("subscribe to user channel: %w", err)
	}
	return nil
}

// Unsubscribe implements Broker.
func (b *RedisBroker) Unsubscribe(ctx context.Context, userID uuid.UUID) error {
	b.mu.Lock()
	defer b.mu.Unlock()

	n, ok := b.users[userID]
	if !ok {
		return nil
	}
	if n--; n > 0 {
		b.users[userID] = n
		return nil
	}

	delete(b.users, userID)
	if err := b.pubsub.Unsubscribe(ctx, channelPrefix+userID.String()); err != nil {
		return fmt.Errorf("unsubscribe from user channel: %w", err)
	}
	return nil
}

// Messages implements Broker.
func (b *RedisBroker) Messages() <-chan []byte { return b.out }

// Close implements Broker.
func (b *RedisBroker) Close() error {
	b.cancel()
	err := b.pubsub.Close()
	b.wg.Wait()
	close(b.out)
	return err
}
