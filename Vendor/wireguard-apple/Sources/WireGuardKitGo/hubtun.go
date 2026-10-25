/* SPDX-License-Identifier: MIT
 *
 * Hub Network's inbound filter: a tun.Device wrapper that decides which packets WireGuard hands to the system. A peer
 * link grant names the ports each side may open on the other; without a filter a linked device would reach every
 * service on this one. Packets from a linked device's addresses pass only to its granted ports, as replies to flows
 * this device started, or as ICMP echo and errors. Other sources pass as before. WireGuard's cryptokey routing makes
 * the source address trustworthy: only the peer whose allowed IPs hold an address can send from it.
 */

package main

import (
	"encoding/json"
	"errors"
	"net"
	"sync"
	"time"

	"golang.zx2c4.com/wireguard/tun"
)

const (
	protocolICMP   = 1
	protocolTCP    = 6
	protocolUDP    = 17
	protocolICMPv6 = 58

	// A flow this device started stays open to replies this long after its last packet
	flowIdleTimeout = 10 * time.Minute
	maxFlows        = 16384
)

// InboundPort is one port a linked device may open on this one.
type InboundPort struct {
	Protocol string `json:"protocol"`
	Port     uint16 `json:"port"`
}

// InboundSource is a linked device's address prefix and the ports it may open.
type InboundSource struct {
	Prefix string        `json:"prefix"`
	Ports  []InboundPort `json:"ports"`
}

// InboundFilterConfig is what Swift sets; no sources passes everything.
type InboundFilterConfig struct {
	Sources []InboundSource `json:"sources"`
}

type inboundSource struct {
	prefix *net.IPNet
	ports  map[inboundPort]bool
}

type inboundPort struct {
	protocol uint8
	port     uint16
}

// flowKey is a flow as this device sent it: its own address and port, and the remote one.
type flowKey struct {
	protocol   uint8
	local      [16]byte
	localPort  uint16
	remote     [16]byte
	remotePort uint16
}

type packetInfo struct {
	protocol uint8
	source   net.IP
	dest     net.IP
	srcPort  uint16
	dstPort  uint16
	icmpType uint8
	ports    bool
}

type filteredTUN struct {
	tun.Device
	mu      sync.Mutex
	sources []inboundSource
	flows   map[flowKey]time.Time
	dropped uint64
	now     func() time.Time
}

func newFilteredTUN(device tun.Device) *filteredTUN {
	return &filteredTUN{Device: device, flows: make(map[flowKey]time.Time), now: time.Now}
}

// SetConfig replaces the linked sources; flows this device started stay open.
func (f *filteredTUN) SetConfig(config *InboundFilterConfig) error {
	var sources []inboundSource
	if config != nil {
		for _, source := range config.Sources {
			_, prefix, err := net.ParseCIDR(source.Prefix)
			if err != nil {
				return err
			}
			ports := make(map[inboundPort]bool)
			for _, port := range source.Ports {
				switch port.Protocol {
				case "tcp":
					ports[inboundPort{protocolTCP, port.Port}] = true
				case "udp":
					ports[inboundPort{protocolUDP, port.Port}] = true
				default:
					return errors.New("inbound port protocol must be tcp or udp")
				}
			}
			sources = append(sources, inboundSource{prefix: prefix, ports: ports})
		}
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	f.sources = sources
	return nil
}

// Read is a packet from the system on its way to a peer: it opens its flow to replies.
func (f *filteredTUN) Read(buf []byte, offset int) (int, error) {
	n, err := f.Device.Read(buf, offset)
	if err != nil || n == 0 {
		return n, err
	}
	if info, ok := parsePacket(buf[offset : offset+n]); ok && info.ports {
		key := flowKey{protocol: info.protocol, localPort: info.srcPort, remotePort: info.dstPort}
		copy(key.local[:], info.source.To16())
		copy(key.remote[:], info.dest.To16())
		f.mu.Lock()
		if len(f.sources) > 0 {
			if len(f.flows) >= maxFlows {
				f.sweepLocked()
			}
			if len(f.flows) < maxFlows {
				f.flows[key] = f.now()
			}
		}
		f.mu.Unlock()
	}
	return n, err
}

// Write is a packet from a peer: it reaches the system only if the filter allows it.
func (f *filteredTUN) Write(buf []byte, offset int) (int, error) {
	if !f.allows(buf[offset:]) {
		f.mu.Lock()
		f.dropped++
		f.mu.Unlock()
		return len(buf) - offset, nil
	}
	return f.Device.Write(buf, offset)
}

func (f *filteredTUN) allows(packet []byte) bool {
	f.mu.Lock()
	defer f.mu.Unlock()
	if len(f.sources) == 0 {
		return true
	}
	info, ok := parsePacket(packet)
	if !ok {
		return false
	}
	var source *inboundSource
	for i := range f.sources {
		if f.sources[i].prefix.Contains(info.source) {
			source = &f.sources[i]
			break
		}
	}
	if source == nil {
		return true
	}
	switch info.protocol {
	case protocolICMP:
		// Echo request and reply, unreachable and time exceeded (path MTU discovery needs unreachable)
		return info.icmpType == 0 || info.icmpType == 3 || info.icmpType == 8 || info.icmpType == 11
	case protocolICMPv6:
		// Unreachable, packet too big, time exceeded, echo request and reply
		return info.icmpType == 1 || info.icmpType == 2 || info.icmpType == 3 || info.icmpType == 128 || info.icmpType == 129
	}
	if !info.ports {
		return false
	}
	key := flowKey{protocol: info.protocol, localPort: info.dstPort, remotePort: info.srcPort}
	copy(key.local[:], info.dest.To16())
	copy(key.remote[:], info.source.To16())
	if at, ok := f.flows[key]; ok {
		if f.now().Sub(at) < flowIdleTimeout {
			f.flows[key] = f.now()
			return true
		}
		delete(f.flows, key)
	}
	return source.ports[inboundPort{info.protocol, info.dstPort}]
}

func (f *filteredTUN) sweepLocked() {
	now := f.now()
	for key, at := range f.flows {
		if now.Sub(at) >= flowIdleTimeout {
			delete(f.flows, key)
		}
	}
}

// parsePacket reads the addresses, protocol and ports of an IPv4 or IPv6 packet. Fragments after the first and IPv6
// packets with extension headers carry no ports and report `ports` false.
func parsePacket(packet []byte) (packetInfo, bool) {
	var info packetInfo
	if len(packet) < 1 {
		return info, false
	}
	var payload []byte
	switch packet[0] >> 4 {
	case 4:
		if len(packet) < 20 {
			return info, false
		}
		headerLength := int(packet[0]&0x0f) * 4
		if headerLength < 20 || len(packet) < headerLength {
			return info, false
		}
		info.protocol = packet[9]
		info.source = net.IP(packet[12:16])
		info.dest = net.IP(packet[16:20])
		fragmentOffset := (uint16(packet[6])<<8 | uint16(packet[7])) & 0x1fff
		if fragmentOffset != 0 {
			return info, true
		}
		payload = packet[headerLength:]
	case 6:
		if len(packet) < 40 {
			return info, false
		}
		info.protocol = packet[6]
		info.source = net.IP(packet[8:24])
		info.dest = net.IP(packet[24:40])
		payload = packet[40:]
	default:
		return info, false
	}
	switch info.protocol {
	case protocolTCP, protocolUDP:
		if len(payload) < 4 {
			return info, true
		}
		info.srcPort = uint16(payload[0])<<8 | uint16(payload[1])
		info.dstPort = uint16(payload[2])<<8 | uint16(payload[3])
		info.ports = true
	case protocolICMP, protocolICMPv6:
		if len(payload) < 1 {
			return info, false
		}
		info.icmpType = payload[0]
	}
	return info, true
}

func parseInboundFilter(settings string) (*InboundFilterConfig, error) {
	if settings == "" {
		return nil, nil
	}
	var config InboundFilterConfig
	if err := json.Unmarshal([]byte(settings), &config); err != nil {
		return nil, err
	}
	return &config, nil
}
