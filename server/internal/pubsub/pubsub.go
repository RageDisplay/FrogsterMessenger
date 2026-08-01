// Package pubsub fans messages out between server instances.
//
// A user's devices may be connected to different instances behind a load
// balancer. When an instance routes a message to a device it does not hold, it
// publishes to that user's channel; whichever instance owns the socket picks
// it up and delivers locally.
package pubsub

import (
	"context"

	"github.com/google/uuid"
)

// Broker distributes payloads addressed to a user across instances.
type Broker interface {
	// Publish sends payload to every instance subscribed to userID.
	Publish(ctx context.Context, userID uuid.UUID, payload []byte) error

	// Subscribe starts listening for a user, called when their first device
	// connects to this instance.
	Subscribe(ctx context.Context, userID uuid.UUID) error

	// Unsubscribe stops listening, called when their last device disconnects.
	Unsubscribe(ctx context.Context, userID uuid.UUID) error

	// Messages yields payloads published by other instances.
	Messages() <-chan []byte

	// Close releases resources.
	Close() error
}
