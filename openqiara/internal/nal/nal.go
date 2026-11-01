// Package nal reads what OpenQiara needs of a NAL unit header, in H.264
// (ITU-T H.264 §7.3.1: one byte, forbidden_zero_bit, nal_ref_idc,
// nal_unit_type on 5 bits) and in H.265 (ITU-T H.265 §7.3.1.2: two bytes,
// forbidden_zero_bit, nal_unit_type on 6 bits, nuh_layer_id on 6 bits,
// nuh_temporal_id_plus1 on 3 bits), and tells one codec from the other on
// a sequence parameter set. The NAL units come without their Annex B start
// code, as camera.Sample carries them.
package nal

import (
	"github.com/bluenviron/mediacommon/v2/pkg/codecs/h264"
	"github.com/bluenviron/mediacommon/v2/pkg/codecs/h265"
)

// Codec is the video codec of a stream.
type Codec uint8

const (
	// Unknown: no parameter set seen yet.
	Unknown Codec = iota
	H264
	H265
)

// String names the codec as Home Assistant shows it.
func (c Codec) String() string {
	switch c {
	case H264:
		return "H.264"
	case H265:
		return "H.265"
	}
	return "inconnu"
}

// Option is the codec as hlcamd's command line and openqiara.json name it
// (--use-h264, --use-h265; "video": {"codec": "h265"}).
func (c Codec) Option() string {
	switch c {
	case H264:
		return "h264"
	case H265:
		return "h265"
	}
	return ""
}

// ParseCodec reads a codec name: "h264", "h265", "H.264", "H.265", "hevc",
// "avc", in any case. ok is false for anything else.
func ParseCodec(s string) (c Codec, ok bool) {
	switch lower(s) {
	case "h264", "h.264", "avc":
		return H264, true
	case "h265", "h.265", "hevc":
		return H265, true
	}
	return Unknown, false
}

func lower(s string) string {
	b := []byte(s)
	for i, c := range b {
		if c >= 'A' && c <= 'Z' {
			b[i] = c + 'a' - 'A'
		}
	}
	return string(b)
}

// H.264 NAL unit types (Table 7-1).
const (
	H264Slice  uint8 = 1
	H264IDR    uint8 = 5
	H264SEI    uint8 = 6
	H264SPS    uint8 = 7
	H264PPS    uint8 = 8
	H264AUD    uint8 = 9
	H264Filler uint8 = 12
)

// H.265 NAL unit types (Table 7-1). Types 16 to 23 are the IRAP pictures
// (BLA, IDR, CRA and the two reserved ones): a decoder can start on any.
const (
	H265TrailN    uint8 = 0
	H265TrailR    uint8 = 1
	H265IRAPFirst uint8 = 16
	H265IDRWRADL  uint8 = 19
	H265IDRNLP    uint8 = 20
	H265CRA       uint8 = 21
	H265IRAPLast  uint8 = 23
	H265VPS       uint8 = 32
	H265SPS       uint8 = 33
	H265PPS       uint8 = 34
	H265AUD       uint8 = 35
	H265SEIPrefix uint8 = 39
	H265SEISuffix uint8 = 40
	// H265Unreadable is what H265Type returns for a header too short to
	// read: 63, an unspecified type nothing treats as video.
	H265Unreadable uint8 = 63
)

// H264Type is the 5-bit type of an H.264 NAL unit, 0 (unspecified) when
// the unit is empty.
func H264Type(nal []byte) uint8 {
	if len(nal) == 0 {
		return 0
	}
	return nal[0] & 0x1f
}

// H265Type is the 6-bit type of an H.265 NAL unit, H265Unreadable when the
// two-byte header is not there.
func H265Type(nal []byte) uint8 {
	if len(nal) < 2 {
		return H265Unreadable
	}
	return (nal[0] >> 1) & 0x3f
}

// Type is the NAL unit type read for codec c.
func Type(c Codec, nal []byte) uint8 {
	if c == H265 {
		return H265Type(nal)
	}
	return H264Type(nal)
}

// IsKey tells whether the NAL unit is a picture a decoder can start on: an
// IDR in H.264, an IRAP picture (types 16 to 23) in H.265.
func IsKey(c Codec, nal []byte) bool {
	switch c {
	case H264:
		return H264Type(nal) == H264IDR
	case H265:
		t := H265Type(nal)
		return t >= H265IRAPFirst && t <= H265IRAPLast
	}
	return false
}

// IsParam tells whether the NAL unit is a parameter set: SPS or PPS in
// H.264, VPS, SPS or PPS in H.265.
func IsParam(c Codec, nal []byte) bool {
	switch c {
	case H264:
		t := H264Type(nal)
		return t == H264SPS || t == H264PPS
	case H265:
		t := H265Type(nal)
		return t == H265VPS || t == H265SPS || t == H265PPS
	}
	return false
}

// IsVCL tells whether the NAL unit carries picture data (a slice).
func IsVCL(c Codec, nal []byte) bool {
	switch c {
	case H264:
		t := H264Type(nal)
		return t >= 1 && t <= 5
	case H265:
		return H265Type(nal) < 32
	}
	return false
}

// IsAUD tells whether the NAL unit is an access unit delimiter.
func IsAUD(c Codec, nal []byte) bool {
	switch c {
	case H264:
		return H264Type(nal) == H264AUD
	case H265:
		return H265Type(nal) == H265AUD
	}
	return false
}

// h265BaseLayer tells whether an H.265 header is well formed for the one
// layer hlcamd makes: forbidden_zero_bit 0, nuh_layer_id 0 (its high bit
// is the low bit of the first byte, its five low bits the high bits of the
// second), nuh_temporal_id_plus1 at least 1.
func h265BaseLayer(nal []byte) bool {
	return len(nal) >= 2 && nal[0]&0x81 == 0 && nal[1]>>3 == 0 && nal[1]&7 != 0
}

// Detect tells which codec a sequence parameter set belongs to, Unknown
// for any other NAL unit, or for an SPS that does not parse. An H.264 SPS
// has type 7 in its one-byte header; an H.265 SPS has type 33 in its
// two-byte header, on the base layer. The two cannot be confused: read as
// H.265, an H.264 SPS (0x67) is type 51 on a layer above 31; read as
// H.264, an H.265 SPS (0x42 0x01) is type 2, a data partition no
// Baseline encoder makes. Both are checked by parsing the SPS, so that a
// slice of one codec looking like a parameter set of the other (an H.264
// non-IDR slice 0x41 reads as an H.265 VPS by type alone) never decides.
func Detect(nal []byte) Codec {
	if len(nal) < 4 {
		return Unknown
	}
	if nal[0]&0x80 == 0 && H264Type(nal) == H264SPS {
		var sps h264.SPS
		if sps.Unmarshal(nal) == nil {
			return H264
		}
		return Unknown
	}
	if H265Type(nal) == H265SPS && h265BaseLayer(nal) {
		var sps h265.SPS
		if sps.Unmarshal(nal) == nil {
			return H265
		}
	}
	return Unknown
}

// MayBeSPS is the cheap test Detect is worth running on: an H.264 SPS
// header (type 7, forbidden bit clear) or an H.265 SPS header on the base
// layer (0x42, then 0x01).
func MayBeSPS(nal []byte) bool {
	if len(nal) < 4 {
		return false
	}
	return (nal[0]&0x9f == H264SPS) || (nal[0] == 0x42 && nal[1] == 0x01)
}

// Foreign tells whether a NAL unit, served as codec c, can only belong to
// the other codec, by its header alone. It catches what comes before the
// SPS which proves the other codec (the state only learns it there):
//
//   - under H.264, the base-layer headers of the H.265 VPS, SPS, PPS,
//     delimiter, SEI, key pictures (IDR_W_RADL, CRA) and of the slices
//     TRAIL_N, TRAIL_R and TSA_N. Read as H.264, they are types 0
//     (unspecified), 2 to 4 (data partitions, Extended profile only), 14
//     and above (extensions, reserved, unspecified), or a type 6, 9 to 12
//     with a nal_ref_idc that is not 0 (forbidden): no Baseline, Main or
//     High encoder makes them, a conformant H.264 stream never meets
//     this test;
//   - under H.265, a header off the base layer hlcamd makes (forbidden
//     bit, nuh_layer_id not 0, nuh_temporal_id_plus1 0) or of an
//     unspecified type (48 to 63): every H.264 slice, IDR, SPS and
//     delimiter (odd first byte: nuh_layer_id above 31), its PPS (0x68,
//     type 52; 0x28 or 0x48 followed by a byte above 7).
//
// Slices of the other codec are not told by their header (an H.264 SEI
// can look like an H.265 slice): once its SPS has come, the state's
// Mismatch is what drops them.
func Foreign(c Codec, nal []byte) bool {
	switch c {
	case H264:
		// by the H.264 header alone. Types 0 (unspecified), 2 to
		// 4 (data partitions, Extended profile only), 14 and above (SVC,
		// MVC and 3D extensions, reserved, auxiliary, unspecified) are
		// never made by a Baseline, Main or High encoder; and an SEI, a
		// delimiter, an end of sequence or of stream and a filler (6, 9 to
		// 12) must carry nal_ref_idc 0 (H.264 §7.4.1). Read as H.265
		// headers these are the VPS, SPS, PPS, delimiter and SEI (0x40,
		// 0x42, 0x44, 0x46, 0x4e, 0x50), the slices TRAIL_N, TRAIL_R and
		// TSA_N that reach the hub before the SPS when the stream is caught
		// in the middle of a GOP, and the key pictures IDR_W_RADL (0x26)
		// and CRA (0x2a) when they come without their parameter sets.
		if len(nal) == 0 {
			return false
		}
		t, ref := nal[0]&0x1f, nal[0]>>5
		switch {
		case t == 0, t >= 2 && t <= 4, t >= 14:
			return true
		case (t == 6 || t >= 9 && t <= 12) && ref != 0:
			return true
		}
		return false
	case H265:
		return !h265BaseLayer(nal) || H265Type(nal) >= 48
	}
	return false
}

// Dimensions reads the picture size of a sequence parameter set, 0, 0
// when it cannot be read.
func Dimensions(c Codec, sps []byte) (width, height int) {
	switch c {
	case H264:
		var s h264.SPS
		if s.Unmarshal(sps) == nil {
			return s.Width(), s.Height()
		}
	case H265:
		var s h265.SPS
		if s.Unmarshal(sps) == nil {
			return s.Width(), s.Height()
		}
	}
	return 0, 0
}
