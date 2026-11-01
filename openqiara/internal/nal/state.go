package nal

import (
	"log/slog"
	"sync"
	"sync/atomic"
)

// State is the codec of the camera's stream as OpenQiara knows it: the one
// configured (video.codec in openqiara.json, what every launch of hlcamd
// is told to encode) and the one the stream itself shows on its sequence
// parameter sets. The codec served by every consumer of the media hub
// (RTSP, HLS, HomeKit, HomeKit Secure Video) is always Configured(): it is
// fixed for the life of the daemon, and changing it means restarting
// openqiarad, which reads the setting again. The detected codec only
// checks the setting: a stream that contradicts it is never served as the
// configured codec (the media hub drops its units, see Admit), and
// OnChange tells the daemon so that it logs and publishes the mismatch.
type State struct {
	configured Codec
	detected   atomic.Uint32
	log        *slog.Logger

	// OnChange, when set before the first Observe, is called each time the
	// detected codec changes, from Observe's caller (the media hub's
	// broadcast): it must not block (leave a kick on a channel, log).
	OnChange func(detected Codec)

	mu sync.Mutex // serialises Observe's slow path
}

// NewState returns the state of a stream expected in configured.
func NewState(configured Codec, logger *slog.Logger) *State {
	if logger == nil {
		logger = slog.Default()
	}
	if configured == Unknown {
		configured = H264
	}
	return &State{configured: configured, log: logger}
}

// Configured is the codec of the setting (H.264 when the setting is
// absent), the one served.
func (s *State) Configured() Codec { return s.configured }

// Detected is the codec the stream showed on its last SPS, Unknown before
// any.
func (s *State) Detected() Codec { return Codec(s.detected.Load()) }

// Mismatch tells whether the stream showed a codec other than the setting
// (from that codec's SPS until an SPS of the configured codec).
func (s *State) Mismatch() bool {
	d := s.Detected()
	return d != Unknown && d != s.configured
}

// Admit observes one video NAL unit of the stream and tells whether it may
// be served as the configured codec. It may not while the stream shows
// another codec (Mismatch), nor when its header is one of the other
// codec's that no encoder of the configured codec makes (Foreign: the
// parameter sets and delimiters that come before the SPS which proves the
// other codec). The media hub calls it on every video sample, before any
// subscriber gets it.
func (s *State) Admit(nal []byte) bool {
	s.Observe(nal)
	return !s.Mismatch() && !Foreign(s.configured, nal)
}

// Observe looks at one video NAL unit from the stream and records its
// codec when it is a sequence parameter set. The common case (a slice, or
// an SPS of the codec already detected) costs a byte comparison and an
// atomic load; parsing only happens when the answer would change. It
// returns true when the detected codec changed.
func (s *State) Observe(nal []byte) bool {
	if !MayBeSPS(nal) {
		return false
	}
	cur := s.Detected()
	// The header alone says which codec this SPS would be: no parse when
	// that is what is already known.
	if (cur == H264 && nal[0]&0x9f == H264SPS) || (cur == H265 && nal[0] == 0x42) {
		return false
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	cur = s.Detected()
	c := Detect(nal)
	if c == Unknown || c == cur {
		return false
	}
	s.detected.Store(uint32(c))
	w, h := Dimensions(c, nal)
	if c != s.configured {
		s.log.Error("video: le flux de hlcamd n'est pas dans le codec configuré : il n'est pas servi (relancer openqiarad après avoir corrigé video.codec ou hlcamd)",
			"configure", s.configured.String(), "flux", c.String(), "largeur", w, "hauteur", h)
	} else if cur != Unknown {
		s.log.Warn("video: le flux est revenu au codec configuré, il est de nouveau servi", "codec", c.String(), "largeur", w, "hauteur", h)
	} else {
		s.log.Info("video: codec du flux confirmé", "codec", c.String(), "largeur", w, "hauteur", h)
	}
	if s.OnChange != nil {
		s.OnChange(c)
	}
	return true
}

// Counter counts the NAL units of a stream by kind, for the diagnostics:
// the parameter sets, the key pictures, the other slices, the SEI, the
// access unit delimiters and the rest. Safe for concurrent use.
type Counter struct {
	vps, sps, pps, key, slice, sei, aud, other atomic.Uint64
}

// Add counts one NAL unit read for codec c.
func (k *Counter) Add(c Codec, nal []byte) {
	switch c {
	case H264:
		switch H264Type(nal) {
		case H264SPS:
			k.sps.Add(1)
		case H264PPS:
			k.pps.Add(1)
		case H264IDR:
			k.key.Add(1)
		case 1, 2, 3, 4:
			k.slice.Add(1)
		case H264SEI:
			k.sei.Add(1)
		case H264AUD:
			k.aud.Add(1)
		default:
			k.other.Add(1)
		}
	case H265:
		t := H265Type(nal)
		switch {
		case t == H265VPS:
			k.vps.Add(1)
		case t == H265SPS:
			k.sps.Add(1)
		case t == H265PPS:
			k.pps.Add(1)
		case t >= H265IRAPFirst && t <= H265IRAPLast:
			k.key.Add(1)
		case t < H265IRAPFirst, t > H265IRAPLast && t < H265VPS:
			// non-IRAP VCL units: types 0 to 15, and the reserved VCL
			// types 24 to 31 (never produced by hlcamd, counted as
			// slices rather than as unknown units)
			k.slice.Add(1)
		case t == H265SEIPrefix || t == H265SEISuffix:
			k.sei.Add(1)
		case t == H265AUD:
			k.aud.Add(1)
		default:
			k.other.Add(1)
		}
	default:
		k.other.Add(1)
	}
}

// Snapshot returns the counts, by name.
func (k *Counter) Snapshot() map[string]uint64 {
	return map[string]uint64{
		"vps": k.vps.Load(), "sps": k.sps.Load(), "pps": k.pps.Load(), "key": k.key.Load(),
		"slice": k.slice.Load(), "sei": k.sei.Load(), "aud": k.aud.Load(), "other": k.other.Load(),
	}
}

// Attrs lists the counts for a log line.
func (k *Counter) Attrs() []any {
	return []any{"vps", k.vps.Load(), "sps", k.sps.Load(), "pps", k.pps.Load(), "cle", k.key.Load(),
		"tranche", k.slice.Load(), "sei", k.sei.Load(), "aud", k.aud.Load(), "autre", k.other.Load()}
}
