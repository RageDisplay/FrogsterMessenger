// Package ws implements the realtime WebSocket layer: the connection hub, the
// per-connection read/write pumps, and presence tracking.
package ws

import (
	"context"
	"encoding/json"
	"log/slog"
	"sync"

	"github.com/google/uuid"
)

// ClientKey identifies one live connection.
//
// Routing is per (user, device) rather than per user: a user with three
// devices has three sockets and three independent ratchet sessions, so a
// payload encrypted for device 2 must never be handed to device 1.
type ClientKey struct {
	UserID   uuid.UUID
	DeviceID uuid.UUID
}

// Delivery is a routed frame destined for a specific device.
type Delivery struct {
	Key      ClientKey
	Envelope *Envelope
}

// Hub owns every live connection on this instance.
//
// All mutation of the connection maps happens inside Run's goroutine, which
// keeps registration, unregistration, and routing free of lock ordering
// problems. The mutex guards only read-only lookups made from other
// goroutines.
type Hub struct {
	mu      sync.RWMutex
	clients map[ClientKey]*Client
	byUser  map[uuid.UUID]map[uuid.UUID]*Client

	register   chan *Client
	unregister chan *Client
	deliver    chan Delivery

	log *slog.Logger
}

// NewHub builds a hub.
func NewHub(log *slog.Logger) *Hub {
	return &Hub{
		clients:    make(map[ClientKey]*Client),
		byUser:     make(map[uuid.UUID]map[uuid.UUID]*Client),
		register:   make(chan *Client),
		unregister: make(chan *Client),
		deliver:    make(chan Delivery, 256),
		log:        log,
	}
}

// Run services the hub until ctx is cancelled. It must be called exactly once.
func (h *Hub) Run(ctx context.Context) {
	for {
		select {
		case <-ctx.Done():
			h.closeAll()
			return

		case c := <-h.register:
			h.add(c)

		case c := <-h.unregister:
			h.remove(c)

		case d := <-h.deliver:
			h.dispatch(d)
		}
	}
}

// Register adds a connection. Safe to call from any goroutine.
func (h *Hub) Register(c *Client) { h.register <- c }

// Unregister removes a connection. Safe to call from any goroutine.
func (h *Hub) Unregister(c *Client) { h.unregister <- c }

// Deliver queues a frame for a locally connected device. It reports false when
// the hub's queue is saturated, so the caller can fall back to persisting the
// message rather than blocking the network read loop.
func (h *Hub) Deliver(d Delivery) bool {
	select {
	case h.deliver <- d:
		return true
	default:
		h.log.Warn("hub delivery queue full, dropping to offline path",
			"user_id", d.Key.UserID, "device_id", d.Key.DeviceID)
		return false
	}
}

// add installs a client, displacing any previous connection for the same
// device. A reconnect before the old socket's read deadline expires would
// otherwise leave a stale entry that silently swallows messages.
func (h *Hub) add(c *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()

	if prev, ok := h.clients[c.key]; ok && prev != c {
		h.log.Info("replacing existing connection",
			"user_id", c.key.UserID, "device_id", c.key.DeviceID)
		prev.closeSend()
	}

	h.clients[c.key] = c
	devices, ok := h.byUser[c.key.UserID]
	if !ok {
		devices = make(map[uuid.UUID]*Client)
		h.byUser[c.key.UserID] = devices
	}
	devices[c.key.DeviceID] = c

	h.log.Info("client connected",
		"user_id", c.key.UserID, "device_id", c.key.DeviceID, "total", len(h.clients))
}

// remove drops a client, ignoring a stale entry that was already displaced.
func (h *Hub) remove(c *Client) {
	h.mu.Lock()
	defer h.mu.Unlock()

	cur, ok := h.clients[c.key]
	if !ok || cur != c {
		return
	}

	delete(h.clients, c.key)
	if devices, ok := h.byUser[c.key.UserID]; ok {
		delete(devices, c.key.DeviceID)
		if len(devices) == 0 {
			delete(h.byUser, c.key.UserID)
		}
	}
	c.closeSend()

	h.log.Info("client disconnected",
		"user_id", c.key.UserID, "device_id", c.key.DeviceID, "total", len(h.clients))
}

// dispatch hands a frame to its target connection.
func (h *Hub) dispatch(d Delivery) {
	h.mu.RLock()
	c, ok := h.clients[d.Key]
	h.mu.RUnlock()
	if !ok {
		return
	}

	payload, err := json.Marshal(d.Envelope)
	if err != nil {
		h.log.Error("marshal envelope", "err", err)
		return
	}
	c.enqueue(payload)
}

// IsLocal reports whether a device is connected to this instance.
func (h *Hub) IsLocal(k ClientKey) bool {
	h.mu.RLock()
	defer h.mu.RUnlock()
	_, ok := h.clients[k]
	return ok
}

// LocalDevices lists a user's connections on this instance.
func (h *Hub) LocalDevices(userID uuid.UUID) []ClientKey {
	h.mu.RLock()
	defer h.mu.RUnlock()

	devices, ok := h.byUser[userID]
	if !ok {
		return nil
	}
	out := make([]ClientKey, 0, len(devices))
	for deviceID := range devices {
		out = append(out, ClientKey{UserID: userID, DeviceID: deviceID})
	}
	return out
}

// Count reports the number of live connections, for health and metrics.
func (h *Hub) Count() int {
	h.mu.RLock()
	defer h.mu.RUnlock()
	return len(h.clients)
}

func (h *Hub) closeAll() {
	h.mu.Lock()
	defer h.mu.Unlock()

	for key, c := range h.clients {
		c.closeSend()
		delete(h.clients, key)
	}
	h.byUser = make(map[uuid.UUID]map[uuid.UUID]*Client)
	h.log.Info("hub shut down, all clients closed")
}
