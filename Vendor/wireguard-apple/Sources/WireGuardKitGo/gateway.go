/* SPDX-License-Identifier: MIT
 *
 * Hub Network's internet gateway: a tun.Device wrapper that keeps a member's internet traffic away from the system.
 * A packet tunnel extension can't make macOS forward and NAT packets, so a device that shares its internet ends its
 * members' TCP and UDP flows in a userspace stack (gVisor) and opens each one again from its own sockets: the far end
 * sees this device's address. DNS to this device's overlay addresses goes to the system's resolvers the same way.
 * Overlay traffic for this device itself passes to the system (through the inbound filter) as before.
 */

package main

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
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
	"gvisor.dev/gvisor/pkg/waiter"
)

const (
	gatewayMTU         = 1280
	gatewayNIC         = 1
	gatewayDialTimeout = 10 * time.Second
	// A UDP flow ends after this long without a packet either way; DNS sooner
	gatewayUDPIdle = 2 * time.Minute
	gatewayDNSIdle = 15 * time.Second
	// The system TUN's packets wait here for WireGuard next to the stack's own
	gatewayQueue  = 256
	gatewayOffset = 16
)

// GatewayConfig is what Swift sets; an empty string turns the gateway off.
type GatewayConfig struct {
	// This device's overlay addresses: DNS sent to them is answered
	Addresses []string `json:"addresses"`
}

// GatewayStats is what `wgGatewayStats` reports.
type GatewayStats struct {
	On          bool     `json:"on"`
	TCP         uint64   `json:"tcp"`
	UDP         uint64   `json:"udp"`
	DNS         uint64   `json:"dns"`
	DialFailed  uint64   `json:"dialFailed"`
	PacketsIn   uint64   `json:"packetsIn"`
	PacketsOut  uint64   `json:"packetsOut"`
	Resolvers   []string `json:"resolvers"`
	LastFailure string   `json:"lastFailure,omitempty"`
}

type gatewayPacket struct {
	data []byte
	// The pooled buffer `data` is in, for the system TUN's packets
	buf []byte
	err error
}

type gatewayTUN struct {
	tun.Device

	mu      sync.Mutex
	gateway *gateway
	// Set once the gateway first turns on: from then on reads come through `packets`
	pumping  bool
	packets  chan gatewayPacket
	pool     sync.Pool
	closed   chan struct{}
	closeOne sync.Once
}

func newGatewayTUN(device tun.Device) *gatewayTUN {
	g := &gatewayTUN{Device: device, packets: make(chan gatewayPacket, gatewayQueue), closed: make(chan struct{})}
	g.pool.New = func() interface{} { return make([]byte, gatewayOffset+65535) }
	return g
}

// SetConfig turns the gateway on with `config`, or off with nil.
func (g *gatewayTUN) SetConfig(config *GatewayConfig) error {
	var next *gateway
	if config != nil {
		var err error
		if next, err = newGateway(config, g); err != nil {
			return err
		}
	}
	g.mu.Lock()
	previous := g.gateway
	g.gateway = next
	if next != nil && !g.pumping {
		g.pumping = true
		go g.pump()
	}
	g.mu.Unlock()
	if previous != nil {
		previous.close()
	}
	return nil
}

func (g *gatewayTUN) current() *gateway {
	g.mu.Lock()
	defer g.mu.Unlock()
	return g.gateway
}

// pump reads the system TUN so that Read can take the stack's packets as well.
func (g *gatewayTUN) pump() {
	for {
		buf := g.pool.Get().([]byte)
		n, err := g.Device.Read(buf, gatewayOffset)
		select {
		case g.packets <- gatewayPacket{data: buf[gatewayOffset : gatewayOffset+n], buf: buf, err: err}:
		case <-g.closed:
			return
		}
		if err != nil {
			return
		}
	}
}

// deliver queues a packet from the stack for its peer; a full queue drops it, as a link would.
func (g *gatewayTUN) deliver(packet []byte) {
	select {
	case g.packets <- gatewayPacket{data: packet}:
	default:
	}
}

func (g *gatewayTUN) Read(buf []byte, offset int) (int, error) {
	g.mu.Lock()
	pumping := g.pumping
	g.mu.Unlock()
	if !pumping {
		return g.Device.Read(buf, offset)
	}
	select {
	case packet := <-g.packets:
		n := copy(buf[offset:], packet.data)
		if packet.buf != nil {
			g.pool.Put(packet.buf)
		}
		return n, packet.err
	case <-g.closed:
		return 0, os.ErrClosed
	}
}

func (g *gatewayTUN) Write(buf []byte, offset int) (int, error) {
	if gateway := g.current(); gateway != nil && gateway.claims(buf[offset:]) {
		gateway.inject(buf[offset:])
		return len(buf) - offset, nil
	}
	return g.Device.Write(buf, offset)
}

func (g *gatewayTUN) Close() error {
	g.closeOne.Do(func() { close(g.closed) })
	if gateway := g.current(); gateway != nil {
		gateway.close()
	}
	return g.Device.Close()
}

func (g *gatewayTUN) Stats() GatewayStats {
	if gateway := g.current(); gateway != nil {
		return gateway.stats()
	}
	return GatewayStats{}
}

type gateway struct {
	tun       *gatewayTUN
	stack     *stack.Stack
	endpoint  *channel.Endpoint
	cancel    context.CancelFunc
	addresses map[[16]byte]bool
	// Opens a flow's far end from this device; tests replace it
	dial func(network, address string) (net.Conn, error)

	tcpFlows, udpFlows, dnsFlows, dialFailed, packetsIn, packetsOut atomic.Uint64
	lastFailure                                                     atomic.Value
}

func newGateway(config *GatewayConfig, device *gatewayTUN) (*gateway, error) {
	addresses := make(map[[16]byte]bool)
	for _, value := range config.Addresses {
		ip := net.ParseIP(value)
		if ip == nil {
			return nil, errors.New("gateway address is not an IP address")
		}
		var key [16]byte
		copy(key[:], ip.To16())
		addresses[key] = true
	}
	s := stack.New(stack.Options{
		NetworkProtocols:   []stack.NetworkProtocolFactory{ipv4.NewProtocol, ipv6.NewProtocol},
		TransportProtocols: []stack.TransportProtocolFactory{tcp.NewProtocol, udp.NewProtocol},
	})
	endpoint := channel.New(gatewayQueue, gatewayMTU, "")
	if err := s.CreateNIC(gatewayNIC, endpoint); err != nil {
		s.Close()
		return nil, errors.New(err.String())
	}
	// The stack answers for every address: each flow it accepts is one a member opened to the internet
	s.SetPromiscuousMode(gatewayNIC, true)
	s.SetSpoofing(gatewayNIC, true)
	s.SetRouteTable([]tcpip.Route{
		{Destination: header.IPv4EmptySubnet, NIC: gatewayNIC},
		{Destination: header.IPv6EmptySubnet, NIC: gatewayNIC},
	})
	sack := tcpip.TCPSACKEnabled(true)
	s.SetTransportProtocolOption(tcp.ProtocolNumber, &sack)
	ctx, cancel := context.WithCancel(context.Background())
	g := &gateway{tun: device, stack: s, endpoint: endpoint, cancel: cancel, addresses: addresses,
		dial: func(network, address string) (net.Conn, error) {
			return net.DialTimeout(network, address, gatewayDialTimeout)
		},
	}
	s.SetTransportProtocolHandler(tcp.ProtocolNumber, tcp.NewForwarder(s, 0, 1024, g.forwardTCP).HandlePacket)
	s.SetTransportProtocolHandler(udp.ProtocolNumber, udp.NewForwarder(s, g.forwardUDP).HandlePacket)
	go g.drain(ctx)
	return g, nil
}

func (g *gateway) close() {
	g.cancel()
	g.endpoint.Close()
	g.stack.Close()
}

// drain hands the stack's packets to WireGuard.
func (g *gateway) drain(ctx context.Context) {
	for {
		pkt := g.endpoint.ReadContext(ctx)
		if pkt == nil {
			return
		}
		view := pkt.ToView()
		packet := append([]byte(nil), view.AsSlice()...)
		view.Release()
		pkt.DecRef()
		g.packetsOut.Add(1)
		g.tun.deliver(packet)
	}
}

// claims tells whether a packet from a peer is the gateway's: a member's packet to a public or LAN address, or DNS
// to this device's overlay addresses. Everything else goes to the system.
func (g *gateway) claims(packet []byte) bool {
	info, ok := parsePacket(packet)
	if !ok || !isOverlay(info.source) {
		return false
	}
	if isOverlay(info.dest) {
		var key [16]byte
		copy(key[:], info.dest.To16())
		return g.addresses[key] && info.ports && info.dstPort == 53 &&
			(info.protocol == protocolUDP || info.protocol == protocolTCP)
	}
	if info.protocol != protocolTCP && info.protocol != protocolUDP {
		return false
	}
	return info.dest.IsGlobalUnicast() && !info.dest.Equal(net.IPv4bcast)
}

func (g *gateway) inject(packet []byte) {
	protocol := ipv4.ProtocolNumber
	if packet[0]>>4 == 6 {
		protocol = ipv6.ProtocolNumber
	}
	pkt := stack.NewPacketBuffer(stack.PacketBufferOptions{Payload: buffer.MakeWithData(packet)})
	g.endpoint.InjectInbound(protocol, pkt)
	pkt.DecRef()
	g.packetsIn.Add(1)
}

// target is where a flow goes: its own destination, or a system resolver for DNS to this device.
func (g *gateway) target(id stack.TransportEndpointID) (address string, dns bool) {
	ip := net.IP(id.LocalAddress.AsSlice())
	var key [16]byte
	copy(key[:], ip.To16())
	if g.addresses[key] {
		return resolvers()[0], true
	}
	return net.JoinHostPort(ip.String(), strconv.Itoa(int(id.LocalPort))), false
}

func (g *gateway) failed(err error) {
	g.dialFailed.Add(1)
	g.lastFailure.Store(err.Error())
}

func (g *gateway) forwardTCP(r *tcp.ForwarderRequest) {
	address, dns := g.target(r.ID())
	remote, err := g.dial("tcp", address)
	if err != nil {
		g.failed(err)
		r.Complete(true)
		return
	}
	var queue waiter.Queue
	endpoint, tcpErr := r.CreateEndpoint(&queue)
	if tcpErr != nil {
		remote.Close()
		r.Complete(true)
		return
	}
	r.Complete(false)
	if dns {
		g.dnsFlows.Add(1)
	} else {
		g.tcpFlows.Add(1)
	}
	local := gonet.NewTCPConn(&queue, endpoint)
	go relayTCP(local, remote)
}

func relayTCP(local *gonet.TCPConn, remote net.Conn) {
	done := make(chan struct{}, 2)
	go func() {
		io.Copy(remote, local)
		if remote, ok := remote.(interface{ CloseWrite() error }); ok {
			remote.CloseWrite()
		}
		done <- struct{}{}
	}()
	go func() {
		io.Copy(local, remote)
		local.CloseWrite()
		done <- struct{}{}
	}()
	<-done
	<-done
	local.Close()
	remote.Close()
}

func (g *gateway) forwardUDP(r *udp.ForwarderRequest) bool {
	address, dns := g.target(r.ID())
	var queue waiter.Queue
	endpoint, tcpErr := r.CreateEndpoint(&queue)
	if tcpErr != nil {
		return true
	}
	local := gonet.NewUDPConn(&queue, endpoint)
	remote, err := g.dial("udp", address)
	if err != nil {
		g.failed(err)
		local.Close()
		return true
	}
	idle := gatewayUDPIdle
	if dns {
		g.dnsFlows.Add(1)
		idle = gatewayDNSIdle
	} else {
		g.udpFlows.Add(1)
	}
	go relayUDP(local, remote, idle)
	return true
}

func relayUDP(local *gonet.UDPConn, remote net.Conn, idle time.Duration) {
	var once sync.Once
	stop := func() {
		once.Do(func() {
			local.Close()
			remote.Close()
		})
	}
	copyPackets := func(to, from net.Conn) {
		defer stop()
		buf := make([]byte, 65535)
		for {
			from.SetReadDeadline(time.Now().Add(idle))
			n, err := from.Read(buf)
			if err != nil {
				return
			}
			if _, err := to.Write(buf[:n]); err != nil {
				return
			}
		}
	}
	go copyPackets(remote, local)
	copyPackets(local, remote)
}

func (g *gateway) stats() GatewayStats {
	stats := GatewayStats{
		On: true, TCP: g.tcpFlows.Load(), UDP: g.udpFlows.Load(), DNS: g.dnsFlows.Load(),
		DialFailed: g.dialFailed.Load(), PacketsIn: g.packetsIn.Load(), PacketsOut: g.packetsOut.Load(),
		Resolvers: resolvers(),
	}
	if failure, ok := g.lastFailure.Load().(string); ok {
		stats.LastFailure = failure
	}
	return stats
}

// resolvers are the system's DNS servers as `host:53`, read fresh as networks change; 1.1.1.1 when none is readable.
func resolvers() []string {
	var servers []string
	if file, err := os.Open("/etc/resolv.conf"); err == nil {
		scanner := bufio.NewScanner(file)
		for scanner.Scan() {
			fields := strings.Fields(scanner.Text())
			if len(fields) < 2 || fields[0] != "nameserver" {
				continue
			}
			host, _, _ := strings.Cut(fields[1], "%")
			if ip := net.ParseIP(host); ip == nil || ip.IsLoopback() || isOverlay(ip) {
				continue
			}
			servers = append(servers, net.JoinHostPort(fields[1], "53"))
		}
		file.Close()
	}
	if len(servers) == 0 {
		servers = []string{"1.1.1.1:53"}
	}
	return servers
}

// isOverlay tells whether an address is in Hub Network's 100.96.0.0/11 or fd48:5542:4e45::/48.
func isOverlay(ip net.IP) bool {
	if v4 := ip.To4(); v4 != nil {
		return v4[0] == 100 && v4[1]&0xe0 == 96
	}
	return len(ip) == net.IPv6len && ip[0] == 0xfd && ip[1] == 0x48 && ip[2] == 0x55 && ip[3] == 0x42 &&
		ip[4] == 0x4e && ip[5] == 0x45
}

func parseGateway(settings string) (*GatewayConfig, error) {
	if settings == "" {
		return nil, nil
	}
	var config GatewayConfig
	if err := json.Unmarshal([]byte(settings), &config); err != nil {
		return nil, err
	}
	return &config, nil
}
