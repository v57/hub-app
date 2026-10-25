package main

import (
	"net"
	"os"
	"testing"
	"time"

	"golang.zx2c4.com/wireguard/tun"
)

// fakeTUN hands out queued packets on Read and records what Write lets through.
type fakeTUN struct {
	outbound [][]byte
	written  [][]byte
}

func (f *fakeTUN) File() *os.File { return nil }
func (f *fakeTUN) Read(buf []byte, offset int) (int, error) {
	packet := f.outbound[0]
	f.outbound = f.outbound[1:]
	return copy(buf[offset:], packet), nil
}
func (f *fakeTUN) Write(buf []byte, offset int) (int, error) {
	f.written = append(f.written, append([]byte(nil), buf[offset:]...))
	return len(buf) - offset, nil
}
func (f *fakeTUN) Flush() error             { return nil }
func (f *fakeTUN) MTU() (int, error)        { return 1420, nil }
func (f *fakeTUN) Name() (string, error)    { return "utun-test", nil }
func (f *fakeTUN) Events() <-chan tun.Event { return nil }
func (f *fakeTUN) Close() error             { return nil }

func ipv4Packet(protocol uint8, source, dest string, srcPort, dstPort uint16) []byte {
	packet := make([]byte, 28)
	packet[0] = 0x45
	packet[9] = protocol
	copy(packet[12:16], net.ParseIP(source).To4())
	copy(packet[16:20], net.ParseIP(dest).To4())
	if protocol == protocolICMP {
		packet[20] = byte(dstPort)
		return packet
	}
	packet[20], packet[21] = byte(srcPort>>8), byte(srcPort)
	packet[22], packet[23] = byte(dstPort>>8), byte(dstPort)
	return packet
}

func ipv6Packet(protocol uint8, source, dest string, srcPort, dstPort uint16) []byte {
	packet := make([]byte, 48)
	packet[0] = 0x60
	packet[6] = protocol
	copy(packet[8:24], net.ParseIP(source).To16())
	copy(packet[24:40], net.ParseIP(dest).To16())
	packet[40], packet[41] = byte(srcPort>>8), byte(srcPort)
	packet[42], packet[43] = byte(dstPort>>8), byte(dstPort)
	return packet
}

func (f *filteredTUN) deliver(t *testing.T, packet []byte) bool {
	t.Helper()
	system := f.Device.(*fakeTUN)
	before := len(system.written)
	buf := make([]byte, 16+len(packet))
	copy(buf[16:], packet)
	if _, err := f.Write(buf, 16); err != nil {
		t.Fatal(err)
	}
	return len(system.written) > before
}

func (f *filteredTUN) send(t *testing.T, packet []byte) {
	t.Helper()
	f.Device.(*fakeTUN).outbound = append(f.Device.(*fakeTUN).outbound, packet)
	if _, err := f.Read(make([]byte, 2048), 16); err != nil {
		t.Fatal(err)
	}
}

func TestFilterPassesEverythingWithoutSources(t *testing.T) {
	filter := newFilteredTUN(&fakeTUN{})
	if !filter.deliver(t, ipv4Packet(protocolTCP, "100.96.0.1", "100.96.0.2", 5000, 22)) {
		t.Fatal("dropped before any sources were set")
	}
	config, _ := parseInboundFilter(`{"sources":[]}`)
	_ = filter.SetConfig(config)
	if !filter.deliver(t, ipv4Packet(protocolTCP, "100.96.0.1", "100.96.0.2", 5000, 22)) {
		t.Fatal("dropped with no linked sources")
	}
}

func TestFilterAllowsOnlyGrantedPortsRepliesAndICMP(t *testing.T) {
	filter := newFilteredTUN(&fakeTUN{})
	config, err := parseInboundFilter(`{"sources":[
		{"prefix":"100.96.0.1/32","ports":[{"protocol":"tcp","port":1997}]},
		{"prefix":"fd48:5542:4e45::1/128","ports":[{"protocol":"tcp","port":1997}]},
		{"prefix":"100.96.0.9/32","ports":[]}]}`)
	if err != nil {
		t.Fatal(err)
	}
	if err := filter.SetConfig(config); err != nil {
		t.Fatal(err)
	}
	// The member may open the hub's port, over IPv4 and IPv6
	if !filter.deliver(t, ipv4Packet(protocolTCP, "100.96.0.1", "100.96.0.2", 50000, 1997)) {
		t.Fatal("granted port dropped")
	}
	if !filter.deliver(t, ipv6Packet(protocolTCP, "fd48:5542:4e45::1", "fd48:5542:4e45::2", 50000, 1997)) {
		t.Fatal("granted IPv6 port dropped")
	}
	// Nothing else: SSH, the hub's port over UDP, or the hub's port from a link without it
	for name, packet := range map[string][]byte{
		"ssh":             ipv4Packet(protocolTCP, "100.96.0.1", "100.96.0.2", 50000, 22),
		"udp 1997":        ipv4Packet(protocolUDP, "100.96.0.1", "100.96.0.2", 50000, 1997),
		"link without it": ipv4Packet(protocolTCP, "100.96.0.9", "100.96.0.2", 50000, 1997),
		"ipv6 ssh":        ipv6Packet(protocolTCP, "fd48:5542:4e45::1", "fd48:5542:4e45::2", 50000, 22),
		"garbage":         {0x00, 0x01},
	} {
		if filter.deliver(t, packet) {
			t.Errorf("%s reached the system", name)
		}
	}
	// A device that isn't linked passes as before
	if !filter.deliver(t, ipv4Packet(protocolTCP, "100.96.0.7", "100.96.0.2", 50000, 22)) {
		t.Fatal("unlinked source dropped")
	}
	// Echo passes
	if !filter.deliver(t, ipv4Packet(protocolICMP, "100.96.0.1", "100.96.0.2", 0, 8)) {
		t.Fatal("echo request dropped")
	}
	if filter.deliver(t, ipv4Packet(protocolICMP, "100.96.0.1", "100.96.0.2", 0, 5)) {
		t.Fatal("ICMP redirect reached the system")
	}

	// A flow this device started gets its replies, and only on that flow
	filter.send(t, ipv4Packet(protocolUDP, "100.96.0.2", "100.96.0.1", 6000, 53))
	if !filter.deliver(t, ipv4Packet(protocolUDP, "100.96.0.1", "100.96.0.2", 53, 6000)) {
		t.Fatal("reply to an outbound flow dropped")
	}
	if filter.deliver(t, ipv4Packet(protocolUDP, "100.96.0.1", "100.96.0.2", 54, 6000)) {
		t.Fatal("packet from another remote port took the flow")
	}
	// It closes once idle
	now := time.Now().Add(flowIdleTimeout)
	filter.now = func() time.Time { return now }
	if filter.deliver(t, ipv4Packet(protocolUDP, "100.96.0.1", "100.96.0.2", 53, 6000)) {
		t.Fatal("idle flow still open")
	}
}

func TestFilterRejectsBadRules(t *testing.T) {
	filter := newFilteredTUN(&fakeTUN{})
	for _, settings := range []string{
		`{"sources":[{"prefix":"nonsense","ports":[]}]}`,
		`{"sources":[{"prefix":"10.0.0.0/8","ports":[{"protocol":"sctp","port":1}]}]}`,
	} {
		config, err := parseInboundFilter(settings)
		if err == nil {
			err = filter.SetConfig(config)
		}
		if err == nil {
			t.Errorf("accepted %s", settings)
		}
	}
	if _, err := parseInboundFilter("{"); err == nil {
		t.Error("accepted broken JSON")
	}
}
