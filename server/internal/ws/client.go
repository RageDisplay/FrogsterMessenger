package ws

import (
	"encoding/json"
	"log/slog"
	"sync"
	"time"

	"github.com/gorilla/websocket"
)

const (
	// writeWait bounds a single write.
	writeWait = 10 * time.Second
	// pongWait is how long to wait for a pong before considering the peer gone.
	pongWait = 60 * time.Second
	// pingPeriod must be shorter than pongWait so a ping lands before timeout.
	pingPeriod = (pongWait * 9) / 10
	// maxMessageSize caps an inbound frame. Large payloads (files) go over
	// gRPC instead, so anything bigger here is a client bug or an attack.
	maxMessageSize = 64 << 10
	// sendBuffer bounds per-connection queued output.
	sendBuffer = 256
)

// FrameHandler processes an inbound frame from a client.
type FrameHandler interface {
	HandleFrame(c *Client, env *Envelope)
}

// Client is one WebSocket connection.
//
// It follows gorilla's concurrency contract: exactly one goroutine reads
// (readPump) and exactly one writes (writePump). Nothing else may touch the
// connection directly; other goroutines queue output via enqueue.
type Client struct {
	hub  *Hub
	conn *websocket.Conn
	key  ClientKey

	send      chan []byte
	closeOnce sync.Once

	// closed is shut when readPump exits, letting the connection's owner run
	// cleanup (presence, unsubscribe) without polling.
	closed   chan struct{}
	doneOnce sync.Once

	handler FrameHandler
	log     *slog.Logger
}

// NewClient wraps an upgraded connection.
func NewClient(hub *Hub, conn *websocket.Conn, key ClientKey, handler FrameHandler, log *slog.Logger) *Client {
	return &Client{
		hub:     hub,
		conn:    conn,
		key:     key,
		send:    make(chan []byte, sendBuffer),
		closed:  make(chan struct{}),
		handler: handler,
		log:     log,
	}
}

// Key returns the client's identity.
func (c *Client) Key() ClientKey { return c.key }

// done returns a channel closed once the connection has terminated.
func (c *Client) done() <-chan struct{} { return c.closed }

// markDone signals termination exactly once.
func (c *Client) markDone() {
	c.doneOnce.Do(func() { close(c.closed) })
}

// Start launches the pumps. It returns immediately.
func (c *Client) Start() {
	go c.writePump()
	go c.readPump()
}

// enqueue queues a frame for delivery.
//
// A full buffer means the client cannot keep up. Rather than block the caller
// (which would let one slow consumer stall message routing) or grow without
// bound (which is a memory-exhaustion vector), the connection is closed and
// the client reconnects, draining anything it missed from the offline queue.
func (c *Client) enqueue(payload []byte) {
	select {
	case c.send <- payload:
	default:
		c.log.Warn("client send buffer full, closing connection",
			"user_id", c.key.UserID, "device_id", c.key.DeviceID)
		c.closeSend()
	}
}

// closeSend closes the outbound channel exactly once, stopping writePump.
func (c *Client) closeSend() {
	c.closeOnce.Do(func() { close(c.send) })
}

// readPump reads frames until the peer disconnects or misbehaves.
func (c *Client) readPump() {
	defer func() {
		c.hub.Unregister(c)
		_ = c.conn.Close()
		c.markDone()
	}()

	c.conn.SetReadLimit(maxMessageSize)
	_ = c.conn.SetReadDeadline(time.Now().Add(pongWait))
	c.conn.SetPongHandler(func(string) error {
		return c.conn.SetReadDeadline(time.Now().Add(pongWait))
	})

	for {
		_, raw, err := c.conn.ReadMessage()
		if err != nil {
			if websocket.IsUnexpectedCloseError(err,
				websocket.CloseGoingAway, websocket.CloseNormalClosure) {
				c.log.Info("websocket closed unexpectedly",
					"user_id", c.key.UserID, "device_id", c.key.DeviceID, "err", err)
			}
			return
		}

		// Only identifiers and a byte count are logged. The frame body is
		// ciphertext and must never reach the log.
		c.log.Info("message received",
			"user_id", c.key.UserID, "device_id", c.key.DeviceID, "bytes", len(raw))

		var env Envelope
		if err := json.Unmarshal(raw, &env); err != nil {
			c.sendError("malformed envelope")
			continue
		}

		// The sender is taken from the authenticated connection, never from
		// the frame, so a client cannot forge messages from another user.
		env.Sender = &Address{UserID: c.key.UserID, DeviceID: c.key.DeviceID}

		if c.handler != nil {
			c.handler.HandleFrame(c, &env)
		}
	}
}

// writePump writes queued frames and keeps the connection alive with pings.
func (c *Client) writePump() {
	ticker := time.NewTicker(pingPeriod)
	defer func() {
		ticker.Stop()
		_ = c.conn.Close()
	}()

	for {
		select {
		case payload, ok := <-c.send:
			_ = c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if !ok {
				// The hub closed the channel; tell the peer politely.
				_ = c.conn.WriteMessage(websocket.CloseMessage,
					websocket.FormatCloseMessage(websocket.CloseNormalClosure, ""))
				return
			}
			if err := c.conn.WriteMessage(websocket.TextMessage, payload); err != nil {
				c.log.Info("write failed, closing connection",
					"user_id", c.key.UserID, "device_id", c.key.DeviceID, "err", err)
				return
			}

		case <-ticker.C:
			_ = c.conn.SetWriteDeadline(time.Now().Add(writeWait))
			if err := c.conn.WriteMessage(websocket.PingMessage, nil); err != nil {
				return
			}
		}
	}
}

// Send queues an envelope for this client.
func (c *Client) Send(env *Envelope) {
	payload, err := json.Marshal(env)
	if err != nil {
		c.log.Error("marshal envelope", "err", err)
		return
	}
	c.enqueue(payload)
}

// sendError reports a protocol error to the client.
func (c *Client) sendError(msg string) {
	c.Send(&Envelope{Version: 1, Type: TypeError, Error: msg})
}
