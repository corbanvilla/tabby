package daemon

import (
	"fmt"
	"net"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/stretchr/testify/assert"
)

func TestBroadcastRender_NoClients(t *testing.T) {
	s := newTestServer(t)
	assert.NotPanics(t, func() { s.BroadcastRender() })
}

func TestBroadcastRender_NilCallbackNoClients(t *testing.T) {
	s := newTestServer(t)
	s.clients["@1"] = &ClientInfo{Width: 80, Height: 24}
	assert.NotPanics(t, func() { s.BroadcastRender() })
}

func TestBroadcastRender_CallsRenderForEachClient(t *testing.T) {
	s := newTestServer(t)
	s.clients["@1"] = &ClientInfo{Width: 80, Height: 24}
	s.clients["@2"] = &ClientInfo{Width: 80, Height: 24}

	called := make(map[string]bool)
	var mu sync.Mutex
	s.OnRenderNeeded = func(clientID string, _, _ int) *RenderPayload {
		mu.Lock()
		called[clientID] = true
		mu.Unlock()
		return nil
	}

	s.BroadcastRender()
	// Wait for batch timer to fire
	time.Sleep(s.renderBatchDelay + 10*time.Millisecond)
	mu.Lock()
	assert.True(t, called["@1"])
	assert.True(t, called["@2"])
	mu.Unlock()
}

func TestBroadcastRender_DebugLogCalled(t *testing.T) {
	s := newTestServer(t)
	s.clients["@1"] = &ClientInfo{Width: 80, Height: 24}

	var logCalls atomic.Int32
	s.DebugLog = func(format string, args ...interface{}) { logCalls.Add(1) }
	s.BroadcastRender()
	// Wait for batch timer to fire
	time.Sleep(s.renderBatchDelay + 10*time.Millisecond)
	assert.Greater(t, logCalls.Load(), int32(0))
}

func TestBroadcastRenderToClients_OnlyRendersRequestedClients(t *testing.T) {
	s := newTestServer(t)
	s.clients["@1"] = &ClientInfo{Width: 80, Height: 24}
	s.clients["@2"] = &ClientInfo{Width: 80, Height: 24}

	called := make(map[string]bool)
	var mu sync.Mutex
	s.OnRenderNeeded = func(clientID string, _, _ int) *RenderPayload {
		mu.Lock()
		called[clientID] = true
		mu.Unlock()
		return nil
	}

	s.BroadcastRenderToClients([]string{"@2", "@2", ""})
	time.Sleep(s.renderBatchDelay + 10*time.Millisecond)

	mu.Lock()
	assert.False(t, called["@1"])
	assert.True(t, called["@2"])
	mu.Unlock()
}

func TestSendRenderToClient_ClientNotFound(t *testing.T) {
	s := newTestServer(t)
	s.SendRenderToClient("ghost")
	// Wait for batch timer to fire - should not panic
	time.Sleep(s.renderBatchDelay + 10*time.Millisecond)
}

func TestSendRenderToClient_NilCallback(t *testing.T) {
	s := newTestServer(t)
	s.clients["@1"] = &ClientInfo{Width: 80, Height: 24}
	s.SendRenderToClient("@1")
	// Wait for batch timer to fire - should not panic
	time.Sleep(s.renderBatchDelay + 10*time.Millisecond)
}

func TestSendRenderToClient_CallbackReturnsNil(t *testing.T) {
	s := newTestServer(t)
	s.clients["@1"] = &ClientInfo{Width: 80, Height: 24}
	s.OnRenderNeeded = func(clientID string, _, _ int) *RenderPayload { return nil }
	s.SendRenderToClient("@1")
	// Wait for batch timer to fire - should not panic
	time.Sleep(s.renderBatchDelay + 10*time.Millisecond)
}

func TestSendRenderToClient_DeduplicatesSameContent(t *testing.T) {
	s := newTestServer(t)
	serverConn, clientConn := net.Pipe()
	defer serverConn.Close()
	defer clientConn.Close()

	s.clients["@1"] = &ClientInfo{Conn: serverConn, Width: 80, Height: 24}

	callCount := 0
	s.OnRenderNeeded = func(clientID string, _, _ int) *RenderPayload {
		callCount++
		return &RenderPayload{Content: "stable content"}
	}

	received := make(chan []byte, 10)
	go func() {
		buf := make([]byte, 4096)
		for {
			clientConn.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
			n, err := clientConn.Read(buf)
			if err != nil {
				return
			}
			cp := make([]byte, n)
			copy(cp, buf[:n])
			received <- cp
		}
	}()

	// Queue multiple renders - batching coalesces them into one
	s.SendRenderToClient("@1")
	s.SendRenderToClient("@1")
	s.SendRenderToClient("@1")

	// Wait for batch timer to fire
	time.Sleep(s.renderBatchDelay + 50*time.Millisecond)
	assert.Equal(t, 1, len(received), "batched renders with same content should only be sent once")
}

func TestSendRenderToClient_SendsOnContentChange(t *testing.T) {
	s := newTestServer(t)
	serverConn, clientConn := net.Pipe()
	defer serverConn.Close()
	defer clientConn.Close()

	s.clients["@1"] = &ClientInfo{Conn: serverConn, Width: 80, Height: 24}

	var content atomic.Value
	content.Store("first")
	s.OnRenderNeeded = func(clientID string, _, _ int) *RenderPayload {
		return &RenderPayload{Content: content.Load().(string)}
	}

	received := make(chan []byte, 10)
	go func() {
		buf := make([]byte, 4096)
		for {
			clientConn.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
			n, err := clientConn.Read(buf)
			if err != nil {
				return
			}
			cp := make([]byte, n)
			copy(cp, buf[:n])
			received <- cp
		}
	}()

	// First render
	s.SendRenderToClient("@1")
	time.Sleep(s.renderBatchDelay + 20*time.Millisecond)

	// Second render with different content
	content.Store("second")
	s.SendRenderToClient("@1")
	time.Sleep(s.renderBatchDelay + 50*time.Millisecond)

	assert.Equal(t, 2, len(received), "changed content should trigger two sends")
}

func TestSendRenderToClient_SequenceNumberIncremented(t *testing.T) {
	s := newTestServer(t)
	serverConn, clientConn := net.Pipe()
	defer serverConn.Close()
	defer clientConn.Close()

	s.clients["@1"] = &ClientInfo{Conn: serverConn, Width: 80, Height: 24}

	var contentIdx atomic.Int32
	contents := []string{"alpha", "beta"}
	s.OnRenderNeeded = func(clientID string, _, _ int) *RenderPayload {
		idx := int(contentIdx.Add(1) - 1)
		c := contents[idx]
		return &RenderPayload{Content: c}
	}

	go func() {
		buf := make([]byte, 4096)
		for {
			clientConn.SetReadDeadline(time.Now().Add(200 * time.Millisecond))
			if _, err := clientConn.Read(buf); err != nil {
				return
			}
		}
	}()

	s.seqMu.Lock()
	before := s.sequenceNum
	s.seqMu.Unlock()
	// First render
	s.SendRenderToClient("@1")
	time.Sleep(s.renderBatchDelay + 20*time.Millisecond)
	// Second render with different content
	s.SendRenderToClient("@1")
	time.Sleep(s.renderBatchDelay + 50*time.Millisecond)
	s.seqMu.Lock()
	after := s.sequenceNum
	s.seqMu.Unlock()
	assert.Greater(t, after, before)
}

func TestRenderBatching_CoalescesMultipleRequests(t *testing.T) {
	s := newTestServer(t)
	serverConn, clientConn := net.Pipe()
	defer serverConn.Close()
	defer clientConn.Close()

	s.clients["@1"] = &ClientInfo{Conn: serverConn, Width: 80, Height: 24}

	var renderCount atomic.Int32
	s.OnRenderNeeded = func(clientID string, _, _ int) *RenderPayload {
		count := renderCount.Add(1)
		return &RenderPayload{Content: fmt.Sprintf("render-%d", count)}
	}

	go func() {
		buf := make([]byte, 4096)
		for {
			clientConn.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
			if _, err := clientConn.Read(buf); err != nil {
				return
			}
		}
	}()

	// Queue 5 rapid render requests - should be batched into 1
	for i := 0; i < 5; i++ {
		s.SendRenderToClient("@1")
	}

	// Wait for batch timer to fire
	time.Sleep(s.renderBatchDelay + 20*time.Millisecond)

	// Only one render should have been executed
	assert.Equal(t, int32(1), renderCount.Load(), "batching should coalesce 5 requests into 1 render")
}

func TestRenderBatching_MultipleClientsInOneBatch(t *testing.T) {
	s := newTestServer(t)

	// Create two clients with pipes
	serverConn1, clientConn1 := net.Pipe()
	defer serverConn1.Close()
	defer clientConn1.Close()
	serverConn2, clientConn2 := net.Pipe()
	defer serverConn2.Close()
	defer clientConn2.Close()

	s.clients["@1"] = &ClientInfo{Conn: serverConn1, Width: 80, Height: 24}
	s.clients["@2"] = &ClientInfo{Conn: serverConn2, Width: 80, Height: 24}

	rendered := make(map[string]int)
	var mu sync.Mutex
	s.OnRenderNeeded = func(clientID string, _, _ int) *RenderPayload {
		mu.Lock()
		rendered[clientID]++
		mu.Unlock()
		return &RenderPayload{Content: "content-" + clientID}
	}

	// Drain both connections
	go func() {
		buf := make([]byte, 4096)
		for {
			clientConn1.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
			if _, err := clientConn1.Read(buf); err != nil {
				return
			}
		}
	}()
	go func() {
		buf := make([]byte, 4096)
		for {
			clientConn2.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
			if _, err := clientConn2.Read(buf); err != nil {
				return
			}
		}
	}()

	// Queue renders for both clients multiple times
	s.SendRenderToClient("@1")
	s.SendRenderToClient("@2")
	s.SendRenderToClient("@1")
	s.SendRenderToClient("@2")

	// Wait for batch timer to fire
	time.Sleep(s.renderBatchDelay + 30*time.Millisecond)

	mu.Lock()
	assert.Equal(t, 1, rendered["@1"], "client @1 should be rendered once")
	assert.Equal(t, 1, rendered["@2"], "client @2 should be rendered once")
	mu.Unlock()
}

func TestSendMessage_NilConn(t *testing.T) {
	s := newTestServer(t)
	err := s.sendMessage(nil, Message{Type: MsgPong})
	assert.Error(t, err)
	assert.Contains(t, err.Error(), "nil connection")
}

func TestSendMessage_ValidConn(t *testing.T) {
	s := newTestServer(t)
	serverConn, clientConn := net.Pipe()
	defer serverConn.Close()
	defer clientConn.Close()

	received := make(chan string, 1)
	go func() {
		buf := make([]byte, 4096)
		n, _ := clientConn.Read(buf)
		received <- string(buf[:n])
	}()

	err := s.sendMessage(serverConn, Message{Type: MsgPong, ClientID: "test"})
	assert.NoError(t, err)

	data := <-received
	assert.Contains(t, data, string(MsgPong))
}

func TestSendMessage_ClosedConn(t *testing.T) {
	s := newTestServer(t)
	serverConn, clientConn := net.Pipe()
	clientConn.Close()
	defer serverConn.Close()

	err := s.sendMessage(serverConn, Message{Type: MsgPong})
	assert.Error(t, err)
}
