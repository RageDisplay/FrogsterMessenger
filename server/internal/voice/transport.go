package voice

import (
	"context"
	"errors"
	"net"
	"net/http"
	"net/netip"
	"time"

	"github.com/gorilla/websocket"
)

// ServeUDP relays datagrams arriving on conn until ctx ends.
func (m *Manager) ServeUDP(ctx context.Context, conn *net.UDPConn) error {
	go func() {
		<-ctx.Done()
		_ = conn.Close()
	}()
	buf := make([]byte, MaxPacket+1)
	for {
		n, addr, err := conn.ReadFromUDPAddrPort(buf)
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			var ne net.Error
			if errors.As(err, &ne) && ne.Timeout() {
				continue
			}
			return err
		}
		if n > MaxPacket {
			continue
		}
		pkt := append([]byte(nil), buf[:n]...)
		m.Receive(pkt, udpSender(conn, addr))
	}
}

func udpSender(conn *net.UDPConn, addr netip.AddrPort) Sender {
	return func(pkt []byte) { _, _ = conn.WriteToUDPAddrPort(pkt, addr) }
}

// The WebSocket path, for networks that let nothing but HTTPS through.
// mediaHello bounds how long a socket may stay open before it proves to
// belong to a member. Opening one costs nothing, so it is not allowed to
// linger on that alone. A variable for tests.
var mediaHello = 10 * time.Second

const (
	mediaWrite = 5 * time.Second
	// mediaQueue bounds what waits for a slow socket. Late sound is worse
	// than none, so beyond this datagrams are dropped, not queued.
	mediaQueue = 32
)

// MediaHandler serves the WebSocket path. A socket carries the same sealed
// datagrams as UDP, one per binary message; the first one that opens under
// a member's key is what ties the socket to that member, so no other
// authentication is needed.
func (m *Manager) MediaHandler(checkOrigin func(r *http.Request) bool) http.Handler {
	upgrader := websocket.Upgrader{
		ReadBufferSize:  2048,
		WriteBufferSize: 2048,
		CheckOrigin:     checkOrigin,
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		conn, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			return
		}
		defer conn.Close()
		conn.SetReadLimit(MaxPacket)

		out := make(chan []byte, mediaQueue)
		done := make(chan struct{})
		defer close(done)
		go func() {
			for {
				select {
				case <-done:
					return
				case pkt := <-out:
					_ = conn.SetWriteDeadline(time.Now().Add(mediaWrite))
					if conn.WriteMessage(websocket.BinaryMessage, pkt) != nil {
						_ = conn.Close()
						return
					}
				}
			}
		}()
		send := func(pkt []byte) {
			select {
			case <-done:
			case out <- pkt:
			default:
			}
		}

		_ = conn.SetReadDeadline(time.Now().Add(mediaHello))
		for {
			kind, pkt, err := conn.ReadMessage()
			if err != nil {
				return
			}
			if kind != websocket.BinaryMessage {
				continue
			}
			if m.receive(pkt, send) {
				// A member's socket stays open while they are heard from.
				_ = conn.SetReadDeadline(time.Now().Add(idleTimeout))
			}
		}
	})
}
