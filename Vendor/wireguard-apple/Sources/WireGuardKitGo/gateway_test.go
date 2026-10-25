package main

import (
	"context"
	"io"
	"net"
	"os"
	"sync"
	"testing"
	"time"

	"golang.zx2c4.com/wireguard/tun"
	"gvisor.dev/gvisor/pkg/buffer"
	"gvisor.dev/gvisor/pkg/tcpip"
	"gvisor.dev/gvisor/pkg/tcpip/adapters/gonet"
	"gvisor.dev/gvisor/pkg/tcpip/header"
	"gvisor.dev/gvisor/pkg/tcpip/link/channel"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv4"
	"gvisor.dev/gvisor/pkg/tcpip/network/ipv6"
	"gvisor.dev/gvisor/pkg/tcpip/stack"
	"gvisor.dev/gvisor/pkg/tcpip/transport/tcp"
	"gvisor.dev/gvisor/pkg/tcpip/transport/udp"
)

// systemTUN stands for the system's side: Read blocks until Close, Write records what reached the system.
type systemTUN struct {
	mu      sync.Mutex
	written [][]byte
	closed  chan struct{}
}

func (s *systemTUN) File() *os.File { return nil }
func (s *systemTUN) Read(buf []byte, offset int) (int, error) {
	<-s.closed
	return 0, os.ErrClosed
}
func (s *systemTUN) Write(buf []byte, offset int) (int, error) {
	s.mu.Lock()
	s.written = append(s.written, append([]byte(nil), buf[offset:]...))
	s.mu.Unlock()
	return len(buf) - offset, nil
}
func (s *systemTUN) Flush() error             { return nil }
func (s *systemTUN) MTU() (int, error)        { return 1280, nil }
func (s *systemTUN) Name() (string, error)    { return "utun-test", nil }
func (s *systemTUN) Events() <-chan tun.Event { return nil }
func (s *systemTUN) Close() error             { return nil }

func (s *systemTUN) count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.written)
}

// member is a member device's stack at 100.96.0.1, wired to the gateway the way WireGuard would carry its packets.
func member(t *testing.T, gateway *gatewayTUN) *stack.Stack {
	s := stack.New(stack.Options{
		NetworkProtocols:   []stack.NetworkProtocolFactory{ipv4.NewProtocol, ipv6.NewProtocol},
		TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol},
	})
	endpoint := channel.New(256, gatewayMTU, "")
	if err := s.CreateNIC(1, endpoint); err != nil {
		t.Fatal(err)
	}
	s.AddProtocolAddress(1, tcpip.ProtocolAddress{
		Protocol:          ipv4.ProtocolNumber,
		AddressWithPrefix: tcpip.AddrFromSlice(net.ParseIP("100.96.0.1").To4()).WithPrefix(),
	}, stack.AddressProperties{})
	s.SetRouteTable([]tcpip.Route{{Destination: header.IPv4EmptySubnet, NIC: 1}})
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(func() {
		cancel()
		gateway.Close()
		s.Close()
	})
	go func() {
		for {
			pkt := endpoint.ReadContext(ctx)
			if pkt == nil {
				return
			}
			view := pkt.ToView()
			buf := append(make([]byte, gatewayOffset), view.AsSlice()...)
			view.Release()
			pkt.DecRef()
			gateway.Write(buf, gatewayOffset)
		}
	}()
	go func() {
		buf := make([]byte, gatewayOffset+65535)
		for {
			n, err := gateway.Read(buf, gatewayOffset)
			if err != nil {
				return
			}
			pkt := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(buf[gatewayOffset : gatewayOffset+n])})
			endpoint.InjectInbound(ipv4.ProtocolNumber, pkt)
			pkt.DecRef()
		}
	}()
	return s
}

func gatewayUnderTest(t *testing.T, dial func(network, address string) (net.Conn, error)) (*gatewayTUN, *systemTUN) {
	system := &systemTUN{closed: make(chan struct{})}
	t.Cleanup(func() { close(system.closed) })
	device := newGatewayTUN(system)
	if err := device.SetConfig(&GatewayConfig{Addresses: []string{"100.96.0.2", "fd48:5542:4e45::2"}}); err != nil {
		t.Fatal(err)
	}
	device.current().dial = dial
	return device, system
}

func echoTCP(t *testing.T) string {
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { listener.Close() })
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				io.Copy(conn, conn)
				conn.Close()
			}()
		}
	}()
	return listener.Addr().String()
}

func TestGatewayOpensTCPFromThisDevice(t *testing.T) {
	echo := echoTCP(t)
	var dialed string
	device, system := gatewayUnderTest(t, func(network, address string) (net.Conn, error) {
		dialed = network + " " + address
		return net.Dial(network, echo)
	})
	phone := member(t, device)
	conn, err := gonet.DialTCP(phone, tcpip.FullAddress{NIC: 1, Addr: tcpip.AddrFromSlice(net.ParseIP("203.0.113.10").To4()), Port: 443}, ipv4.ProtocolNumber)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := conn.Write([]byte("hello")); err != nil {
		t.Fatal(err)
	}
	reply := make([]byte, 5)
	if _, err := io.ReadFull(conn, reply); err != nil || string(reply) != "hello" {
		t.Fatalf("reply %q, %v", reply, err)
	}
	if dialed != "tcp 203.0.113.10:443" {
		t.Fatalf("dialed %q", dialed)
	}
	if system.count() != 0 {
		t.Fatalf("%d packets reached the system", system.count())
	}
	if stats := device.Stats(); !stats.On || stats.TCP != 1 {
		t.Fatalf("stats %+v", stats)
	}
}

func TestGatewayResetsWhenTheFarEndRefuses(t *testing.T) {
	device, _ := gatewayUnderTest(t, func(network, address string) (net.Conn, error) {
		return nil, &net.OpError{Op: "dial", Net: network, Err: os.ErrDeadlineExceeded}
	})
	phone := member(t, device)
	_, err := gonet.DialTCP(phone, tcpip.FullAddress{NIC: 1, Addr: tcpip.AddrFromSlice(net.ParseIP("203.0.113.10").To4()), Port: 443}, ipv4.ProtocolNumber)
	if err == nil {
		t.Fatal("connected to a far end that refused")
	}
	if device.Stats().DialFailed != 1 {
		t.Fatalf("stats %+v", device.Stats())
	}
}

func TestGatewayAnswersDNSOnItsOverlayAddress(t *testing.T) {
	upstream, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer upstream.Close()
	go func() {
		buf := make([]byte, 512)
		for {
			n, from, err := upstream.ReadFrom(buf)
			if err != nil {
				return
			}
			upstream.WriteTo(append([]byte("answer:"), buf[:n]...), from)
		}
	}()
	var dialed string
	device, system := gatewayUnderTest(t, func(network, address string) (net.Conn, error) {
		dialed = network + " " + address
		return net.Dial(network, upstream.LocalAddr().String())
	})
	phone := member(t, device)
	conn, err := gonet.DialUDP(phone, nil, &tcpip.FullAddress{NIC: 1, Addr: tcpip.AddrFromSlice(net.ParseIP("100.96.0.2").To4()), Port: 53}, ipv4.ProtocolNumber)
	if err != nil {
		t.Fatal(err)
	}
	defer conn.Close()
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	conn.Write([]byte("query"))
	reply := make([]byte, 64)
	n, err := conn.Read(reply)
	if err != nil || string(reply[:n]) != "answer:query" {
		t.Fatalf("reply %q, %v", reply[:n], err)
	}
	if dialed != "udp "+resolvers()[0] {
		t.Fatalf("dialed %q, resolvers %v", dialed, resolvers())
	}
	if system.count() != 0 {
		t.Fatalf("%d packets reached the system", system.count())
	}
}

func TestGatewayLeavesOverlayTrafficToTheSystem(t *testing.T) {
	device, system := gatewayUnderTest(t, func(network, address string) (net.Conn, error) {
		t.Errorf("dialed %s %s", network, address)
		return nil, os.ErrInvalid
	})
	for _, packet := range [][]byte{
		ipv4Packet(protocolTCP, "100.96.0.1", "100.96.0.2", 50000, 1997), // this device's hub
		ipv4Packet(protocolUDP, "100.96.0.1", "100.96.0.3", 50000, 53),   // DNS to another member
		ipv4Packet(protocolICMP, "100.96.0.1", "1.1.1.1", 0, 8),          // ping isn't forwarded
		ipv4Packet(protocolTCP, "192.0.2.1", "1.1.1.1", 50000, 443),      // not a member's address
		ipv4Packet(protocolTCP, "100.96.0.1", "127.0.0.1", 50000, 22),    // this device's loopback
	} {
		buf := append(make([]byte, gatewayOffset), packet...)
		device.Write(buf, gatewayOffset)
	}
	if system.count() != 5 {
		t.Fatalf("%d of 5 packets reached the system", system.count())
	}
	if stats := device.Stats(); stats.PacketsIn != 0 {
		t.Fatalf("stats %+v", stats)
	}
}

func TestGatewayOffPassesEverything(t *testing.T) {
	system := &systemTUN{closed: make(chan struct{})}
	defer close(system.closed)
	device := newGatewayTUN(system)
	buf := append(make([]byte, gatewayOffset), ipv4Packet(protocolTCP, "100.96.0.1", "1.1.1.1", 50000, 443)...)
	device.Write(buf, gatewayOffset)
	if system.count() != 1 || device.Stats().On {
		t.Fatalf("%d packets reached the system, stats %+v", system.count(), device.Stats())
	}
}
