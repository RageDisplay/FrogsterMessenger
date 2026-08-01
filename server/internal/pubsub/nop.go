package pubsub

import (
	"context"

	"github.com/google/uuid"
)

// NopBroker is a single-instance no-op broker for development and tests.
//
// With one server instance every recipient socket is local, so cross-instance
// fan-out is unnecessary. Publishing discards the payload: the caller has
// already tried local delivery and persisted anything undeliverable.
type NopBroker struct {
	out chan []byte
}

// NewNopBroker builds a broker that never delivers anything.
func NewNopBroker() *NopBroker {
	return &NopBroker{out: make(chan []byte)}
}

// Publish implements Broker.
func (b *NopBroker) Publish(context.Context, uuid.UUID, []byte) error { return nil }

// Subscribe implements Broker.
func (b *NopBroker) Subscribe(context.Context, uuid.UUID) error { return nil }

// Unsubscribe implements Broker.
func (b *NopBroker) Unsubscribe(context.Context, uuid.UUID) error { return nil }

// Messages implements Broker.
func (b *NopBroker) Messages() <-chan []byte { return b.out }

// Close implements Broker.
func (b *NopBroker) Close() error {
	close(b.out)
	return nil
}
