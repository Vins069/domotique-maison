// Package rtspserver exposes the camera's stream, H.264 or H.265 as
// video.codec says, as a standard RTSP service for Scrypted,
// Frigate or VLC, from the media hub that feeds the HomeKit path too. With
// the multicast source, the microphone comes along as AAC-LC (RFC 3640),
// encoded here from the hub's PCM.
package rtspserver

import (
	"bytes"
	"context"
	"encoding/base64"
	"fmt"
	"log/slog"
	"os"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/bluenviron/gortsplib/v5"
	"github.com/bluenviron/gortsplib/v5/pkg/base"
	"github.com/bluenviron/gortsplib/v5/pkg/description"
	"github.com/bluenviron/gortsplib/v5/pkg/format"
	"github.com/bluenviron/gortsplib/v5/pkg/format/rtph264"
	"github.com/bluenviron/gortsplib/v5/pkg/format/rtph265"
	"github.com/bluenviron/gortsplib/v5/pkg/format/rtpmpeg4audio"
	"github.com/bluenviron/mediacommon/v2/pkg/codecs/mpeg4audio"
	"github.com/pion/rtp"

	"github.com/caligone/openqiara/internal/aacenc"
	"github.com/caligone/openqiara/internal/camera"
	"github.com/caligone/openqiara/internal/mediahub"
	"github.com/caligone/openqiara/internal/nal"
)

// nalType returns the 5-bit H.264 NAL unit type from a NAL unit with no
// Annex B start code (camera.Sample's form).
func nalType(n []byte) uint8 { return nal.H264Type(n) }

const (
	nalTypeSPS = nal.H264SPS
	nalTypePPS = nal.H264PPS
)

// rtpEncoder is what the H.264 and H.265 packetizers of gortsplib share.
type rtpEncoder interface {
	Encode(au [][]byte) ([]*rtp.Packet, error)
}

// Config configures the RTSP server.
type Config struct {
	// Listen is the address the RTSP server binds to, e.g. ":8554".
	Listen string
	// Path is the RTSP stream path, e.g. "openqiara" →
	// rtsp://host:8554/openqiara.
	Path string
	// Audio adds the microphone, when the hub carries it (multicast
	// source) and libfdk-aac is at hand.
	Audio bool
	// ParamsFile, when set, persists the last H.264 SPS/PPS seen on the
	// stream so that DESCRIBE advertises them (sprop-parameter-sets and
	// profile-level-id) even before the camera pipeline starts. Without
	// them, some clients (go2rtc → MSE players) build their decoder config
	// from a placeholder and display the picture with a wrong 4:3 aspect.
	ParamsFile string
	// ParamsFileH265 does the same for the H.265 VPS/SPS/PPS (sprop-vps,
	// sprop-sps, sprop-pps), in a file of its own: each codec keeps its
	// parameter sets when video.codec is changed (and openqiarad
	// restarted) back and forth.
	ParamsFileH265 string
}

// The microphone as RTSP serves it: AAC-LC 16 kHz mono, one 64 ms access
// unit per packet.
const (
	audioRate    = 16000
	audioBitrate = 32000
)

// Server serves a single video stream over RTSP, in the codec configured
// (H.264 or H.265), fixed for the server's life. The camera pipeline runs
// only while at least one client is reading, mirroring the on-demand
// behaviour of the HomeKit path so hlcamd isn't kept awake needlessly.
type Server struct {
	cfg  Config
	log  *slog.Logger
	hub  *mediahub.Hub
	rsrv *gortsplib.Server

	// codec is the stream's codec as configured and as seen;
	// nil: H.264, as before.
	codec *nal.State
	// served is the codec configured, set at Start and never changed: the
	// description, forma and the pipeline's packetizer are its. The hub
	// drops the units of any other codec (nal.State.Admit), so none is
	// ever packetized as this one.
	served nal.Codec

	mu       sync.Mutex
	stream   *gortsplib.ServerStream
	forma    format.Format      // *format.H264 or *format.H265
	audio    *format.MPEG4Audio // nil: video only
	desc     *description.Session
	readers  int
	cancelPL context.CancelFunc // cancels the running pipeline goroutine

	// randomStart offsets RTP timestamps per RFC 3550 §5.1; fixed for the
	// server's lifetime so all readers share a consistent timeline.
	randomStart uint32

	// vps/sps/pps are cached from the stream so we can re-emit them before
	// each key picture for clients that joined mid-GOP (vps: H.265 only).
	vps []byte
	sps []byte
	pps []byte

	// paquets jetés par client (résumé périodique, voir OnStreamWriteError)
	dropMu sync.Mutex
	drops  map[*gortsplib.ServerSession]*dropStat

	// resync : après un paquet jeté, les images suivantes ne sont
	// plus envoyées jusqu'à la prochaine image clé. Une image amputée abîme
	// toutes celles qui en dépendent jusqu'à l'image clé : les envoyer ne sert
	// qu'à remplir encore la file d'un client déjà en retard. skipped compte
	// les images ainsi sautées (résumé périodique).
	resync  atomic.Bool
	skipped atomic.Int64
}

// keepAU tells whether an access unit goes out: every one, except
// after a dropped packet, until the next key frame, which ends the wait.
func (s *Server) keepAU(hasIDR bool) bool {
	if !s.resync.Load() {
		return true
	}
	if !hasIDR {
		s.skipped.Add(1)
		return false
	}
	s.resync.Store(false)
	return true
}

// New returns an RTSP server. The hub is the shared media pipeline the
// server subscribes to on the first reader; if nil, New panics — the RTSP
// server has no standalone pipeline anymore. Call Start to bind and serve.
func New(cfg Config, hub *mediahub.Hub, logger *slog.Logger) *Server {
	if logger == nil {
		logger = slog.Default()
	}
	if cfg.Path == "" {
		cfg.Path = "openqiara"
	}
	return &Server{cfg: cfg, hub: hub, log: logger}
}

// SetCodecState attaches the stream's codec state, the one the hub feeds.
// Call before Start. Without it the server is H.264 only.
func (s *Server) SetCodecState(st *nal.State) { s.codec = st }

// configured is the codec to serve: the setting's, H.264 without a state.
func (s *Server) configured() nal.Codec {
	if s.codec == nil {
		return nal.H264
	}
	return s.codec.Configured()
}

// proven tells whether the stream has shown its codec on an SPS. Before
// that, the pipeline waits for a key picture (the SPS comes with it):
// slices met before the first SPS are not told apart by their header
// (nal.Foreign), and packetizing those of a codec the setting may be
// wrong about would serve an invalid stream for the length of a GOP.
func (s *Server) proven() bool {
	return s.codec == nil || s.codec.Detected() != nal.Unknown
}

// newVideoFormat is the RTP format of codec c, with the parameter sets
// persisted for it, if any, so that DESCRIBE advertises them before the
// pipeline runs.
func (s *Server) newVideoFormat(c nal.Codec) format.Format {
	if c == nal.H265 {
		f := &format.H265{PayloadTyp: 96}
		if vps, sps, pps, ok := loadParamsH265(s.cfg.ParamsFileH265); ok {
			f.VPS, f.SPS, f.PPS = vps, sps, pps
			s.log.Info("rtsp: H.265 parameter sets restored for DESCRIBE", "file", s.cfg.ParamsFileH265)
		}
		return f
	}
	// H.264 format with a dynamic payload type. The camera emits SPS/PPS
	// in-band, so clients pick up parameter sets before the first IDR; we
	// also re-emit them ourselves ahead of each IDR (see writeAU).
	f := &format.H264{PayloadTyp: 96, PacketizationMode: 1}
	if sps, pps, ok := loadParams(s.cfg.ParamsFile); ok {
		f.SPS, f.PPS = sps, pps
		s.log.Info("rtsp: H.264 parameter sets restored for DESCRIBE", "file", s.cfg.ParamsFile)
	}
	return f
}

// Start binds the RTSP listener and begins serving. It returns once the
// listener is up; serving continues in the background until ctx is
// cancelled.
func (s *Server) Start(ctx context.Context) error {
	rs, err := randUint32()
	if err != nil {
		return fmt.Errorf("rtsp: random ts: %w", err)
	}
	s.randomStart = rs

	if s.cfg.Audio {
		if enc, err := aacenc.New(aacenc.LC, audioRate, audioBitrate); err != nil {
			s.log.Warn("rtsp: no AAC encoder, video only", "error", err)
		} else {
			enc.Close()
			s.audio = &format.MPEG4Audio{
				PayloadTyp: 97,
				Config: &mpeg4audio.AudioSpecificConfig{
					Type: mpeg4audio.ObjectTypeAACLC, SampleRate: audioRate, ChannelConfig: 1,
				},
				SizeLength: 13, IndexLength: 3, IndexDeltaLength: 3,
			}
		}
	}
	// The video format and the description: the codec configured, with
	// the parameter sets persisted for it, so that DESCRIBE answers
	// before the pipeline has run.
	s.served = s.configured()
	s.forma = s.newVideoFormat(s.served)
	medias := []*description.Media{{Type: description.MediaTypeVideo, Formats: []format.Format{s.forma}}}
	if s.audio != nil {
		medias = append(medias, &description.Media{Type: description.MediaTypeAudio, Formats: []format.Format{s.audio}})
	}
	s.desc = &description.Session{Medias: medias}
	s.log.Info("rtsp: codec servi", "codec", s.served.String())

	s.rsrv = &gortsplib.Server{
		Handler:     s,
		RTSPAddress: s.cfg.Listen,
		// File d'attente d'écriture par client (paquets RTP). La valeur par défaut (256, ~0,6 s à 4 Mbit/s)
		// débordait au moindre creux du Wi-Fi 2,4 GHz de la caméra : des paquets étaient jetés, d'où des
		// images abîmées puis figées jusqu'à l'image clé suivante (Claude, 25/10/2026). 2048 paquets
		// absorbent ~5 s de creux ; mémoire utilisée seulement pendant un creux (~3 Mo au pire).
		WriteQueueSize: writeQueueSize,
	}
	if err := s.rsrv.Start(); err != nil {
		return fmt.Errorf("rtsp listen %s: %w", s.cfg.Listen, err)
	}
	s.log.Info("rtsp server listening", "addr", s.cfg.Listen, "path", s.cfg.Path)

	go func() {
		<-ctx.Done()
		s.rsrv.Close()
	}()
	return nil
}

// --- gortsplib.ServerHandler ---

// writeQueueSize : file d'attente d'écriture par client RTSP (puissance de deux exigée par gortsplib).
const writeQueueSize = 2048

// OnStreamWriteError implements gortsplib.ServerHandlerOnStreamWriteError. Sans ce gestionnaire, gortsplib
// écrit une ligne de journal par paquet jeté (des centaines par seconde sur la carte SD) ; ici, un résumé
// au plus toutes les 10 s par client.
func (s *Server) OnStreamWriteError(ctx *gortsplib.ServerHandlerOnStreamWriteErrorCtx) {
	s.dropMu.Lock()
	defer s.dropMu.Unlock()
	if s.drops == nil {
		s.drops = make(map[*gortsplib.ServerSession]*dropStat)
	}
	d := s.drops[ctx.Session]
	if d == nil {
		d = &dropStat{}
		s.drops[ctx.Session] = d
	}
	d.n++
	s.resync.Store(true)
	now := time.Now()
	if now.Sub(d.last) >= 10*time.Second {
		s.log.Warn("rtsp: client trop lent, paquets ignorés", "client", d.addr, "paquets", d.n,
			"images_sautees_jusqu_a_l_image_cle", s.skipped.Swap(0), "erreur", ctx.Error)
		d.n = 0
		d.last = now
	}
}

type dropStat struct {
	addr string
	n    int
	last time.Time
}

// OnConnOpen implements gortsplib.ServerHandlerOnConnOpen.
func (s *Server) OnConnOpen(_ *gortsplib.ServerHandlerOnConnOpenCtx) {}

// OnConnClose implements gortsplib.ServerHandlerOnConnClose.
func (s *Server) OnConnClose(_ *gortsplib.ServerHandlerOnConnCloseCtx) {}

// OnSessionOpen implements gortsplib.ServerHandlerOnSessionOpen : retient l'adresse du client pour le
// résumé des paquets jetés.
func (s *Server) OnSessionOpen(ctx *gortsplib.ServerHandlerOnSessionOpenCtx) {
	addr := ""
	if ctx.Conn != nil && ctx.Conn.NetConn() != nil {
		addr = ctx.Conn.NetConn().RemoteAddr().String()
	}
	s.dropMu.Lock()
	if s.drops == nil {
		s.drops = make(map[*gortsplib.ServerSession]*dropStat)
	}
	s.drops[ctx.Session] = &dropStat{addr: addr}
	s.dropMu.Unlock()
}

// OnSessionClose implements gortsplib.ServerHandlerOnSessionClose. A
// closing session that was reading counts as a reader leaving.
func (s *Server) OnSessionClose(ctx *gortsplib.ServerHandlerOnSessionCloseCtx) {
	s.dropMu.Lock()
	delete(s.drops, ctx.Session)
	s.dropMu.Unlock()
	if ctx.Session.State() == gortsplib.ServerSessionStatePlay {
		s.onReaderGone()
	}
}

// OnDescribe advertises the single video stream, creating it on demand.
func (s *Server) OnDescribe(_ *gortsplib.ServerHandlerOnDescribeCtx) (*base.Response, *gortsplib.ServerStream, error) {
	st, err := s.ensureStream()
	if err != nil {
		return &base.Response{StatusCode: base.StatusInternalServerError}, nil, err
	}
	return &base.Response{StatusCode: base.StatusOK}, st, nil
}

// OnSetup returns the shared stream for the requested media.
func (s *Server) OnSetup(_ *gortsplib.ServerHandlerOnSetupCtx) (*base.Response, *gortsplib.ServerStream, error) {
	st, err := s.ensureStream()
	if err != nil {
		return &base.Response{StatusCode: base.StatusInternalServerError}, nil, err
	}
	return &base.Response{StatusCode: base.StatusOK}, st, nil
}

// OnPlay starts the camera pipeline for the first concurrent reader.
func (s *Server) OnPlay(_ *gortsplib.ServerHandlerOnPlayCtx) (*base.Response, error) {
	s.mu.Lock()
	s.readers++
	first := s.readers == 1
	s.mu.Unlock()
	if first {
		s.startPipeline()
	}
	return &base.Response{StatusCode: base.StatusOK}, nil
}

// ensureStream lazily creates the shared ServerStream.
func (s *Server) ensureStream() (*gortsplib.ServerStream, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.stream != nil {
		return s.stream, nil
	}
	st := &gortsplib.ServerStream{Server: s.rsrv, Desc: s.desc}
	if err := st.Initialize(); err != nil {
		return nil, fmt.Errorf("rtsp: stream init: %w", err)
	}
	s.stream = st
	return st, nil
}

// onReaderGone stops the pipeline once the last reader leaves.
func (s *Server) onReaderGone() {
	s.mu.Lock()
	if s.readers > 0 {
		s.readers--
	}
	last := s.readers == 0
	cancel := s.cancelPL
	if last {
		s.cancelPL = nil
	}
	s.mu.Unlock()

	if last && cancel != nil {
		cancel()
	}
}

// --- pipeline ---

// startPipeline launches the HLS→MPEG-TS→NAL→RTP goroutine.
func (s *Server) startPipeline() {
	plCtx, cancel := context.WithCancel(context.Background())
	s.mu.Lock()
	s.cancelPL = cancel
	s.mu.Unlock()
	go s.runPipeline(plCtx)
}

// runPipeline subscribes to the shared media hub and packetizes its
// samples to RTP through gortsplib: NAL grouped into access units, PCM
// encoded to AAC-LC when the stream has audio.
func (s *Server) runPipeline(ctx context.Context) {
	codec := s.served
	enc, err := newRTPEncoder(codec, s.forma.PayloadType())
	if err != nil {
		s.log.Error("rtsp: encoder init", "error", err)
		return
	}

	var audio *audioEncoder
	if s.audio != nil {
		a, err := newAudioEncoder(s.audio)
		if err != nil {
			s.log.Warn("rtsp: audio encoder", "error", err)
		} else {
			audio = a
			defer audio.close()
		}
	}

	sub := s.hub.Subscribe()
	defer sub.Close()

	// The parser emits one NAL per Sample. gortsplib's encoder wants a
	// whole access unit ([][]byte), so we buffer NAL of the same PTS and
	// flush the group when the PTS advances (or an AUD/new IDR marks a
	// boundary).
	s.log.Info("rtsp: pipeline started (via mediahub)", "audio", audio != nil, "codec", codec.String())
	var au [][]byte
	var auPTS int64
	havePTS := false

	flush := func() {
		if len(au) == 0 {
			return
		}
		s.writeAU(enc, au, auPTS)
		au = au[:0]
	}

	for {
		select {
		case <-ctx.Done():
			flush()
			s.log.Info("rtsp: pipeline stopped", s.hub.NALCountAttrs()...)
			return
		case sample, ok := <-sub.Samples():
			if !ok {
				flush()
				return
			}
			if !sample.IsVideo {
				if audio != nil {
					s.writeAudio(audio, sample)
				}
				continue
			}
			if havePTS && sample.PTS != auPTS {
				flush()
			}
			auPTS = sample.PTS
			havePTS = true
			au = append(au, append([]byte(nil), sample.Data...))
		}
	}
}

// newRTPEncoder is the packetizer of codec c (RFC 6184 for H.264, RFC 7798
// for H.265) on payload type pt.
func newRTPEncoder(c nal.Codec, pt uint8) (rtpEncoder, error) {
	if c == nal.H265 {
		e := &rtph265.Encoder{PayloadType: pt}
		if err := e.Init(); err != nil {
			return nil, err
		}
		return e, nil
	}
	e := &rtph264.Encoder{PayloadType: pt, PacketizationMode: 1}
	if err := e.Init(); err != nil {
		return nil, err
	}
	return e, nil
}

// writeAU caches parameter sets, prepends them ahead of a key picture for
// mid-GOP joiners, encodes the access unit to RTP and writes it to all
// readers. The unit is of the codec served: the hub let through no other.
func (s *Server) writeAU(enc rtpEncoder, au [][]byte, pts90khz int64) {
	codec := s.served
	hasKey := false
	paramsChanged := false
	cache := func(dst *[]byte, n []byte) {
		s.mu.Lock()
		if !bytes.Equal(*dst, n) {
			paramsChanged = true
		}
		*dst = append([]byte(nil), n...)
		s.mu.Unlock()
	}
	for _, n := range au {
		switch {
		case codec == nal.H265 && nal.H265Type(n) == nal.H265VPS:
			cache(&s.vps, n)
		case nal.Type(codec, n) == paramTypeSPS(codec):
			cache(&s.sps, n)
		case nal.Type(codec, n) == paramTypePPS(codec):
			cache(&s.pps, n)
		case nal.IsKey(codec, n):
			hasKey = true
		}
	}
	if paramsChanged {
		s.publishParams()
	}
	// The stream has not shown its SPS yet: nothing goes out before the
	// key picture that brings it (see proven).
	if !hasKey && !s.proven() {
		return
	}
	if !s.keepAU(hasKey) {
		return
	}

	out := au
	if hasKey {
		s.mu.Lock()
		vps, sps, pps := s.vps, s.sps, s.pps
		s.mu.Unlock()
		if len(sps) > 0 && len(pps) > 0 && !auHasParams(codec, au) {
			if codec == nal.H265 {
				if len(vps) > 0 {
					out = append([][]byte{vps, sps, pps}, au...)
				}
			} else {
				out = append([][]byte{sps, pps}, au...)
			}
		}
	}

	pkts, err := enc.Encode(out)
	if err != nil {
		s.log.Warn("rtsp: encode error", "error", err)
		return
	}
	ts := uint32(int64(s.randomStart) + pts90khz)
	s.mu.Lock()
	st := s.stream
	s.mu.Unlock()
	if st == nil {
		return
	}
	for _, p := range pkts {
		p.Timestamp = ts
		if err := st.WritePacketRTP(s.desc.Medias[0], p); err != nil {
			s.log.Warn("rtsp: write error", "error", err)
			return
		}
	}
}

// paramTypeSPS and paramTypePPS are the SPS and PPS types of a codec.
func paramTypeSPS(c nal.Codec) uint8 {
	if c == nal.H265 {
		return nal.H265SPS
	}
	return nal.H264SPS
}

func paramTypePPS(c nal.Codec) uint8 {
	if c == nal.H265 {
		return nal.H265PPS
	}
	return nal.H264PPS
}

// publishParams advertises the cached parameter sets in the session
// description served to future DESCRIBE requests, and persists them for
// the next start. The slices are fresh copies (see writeAU), never mutated
// afterwards, so sharing them with the format and its clones is safe. The
// format's fields are read and set under s.mu: ensureStream clones the
// format (gortsplib reads the fields by reflection) while holding it (axe
// F, 28/10/2026); ReloadDesc then hands the new fields to the stream.
func (s *Server) publishParams() {
	s.mu.Lock()
	vps, sps, pps, st, forma := s.vps, s.sps, s.pps, s.stream, s.forma
	s.mu.Unlock()
	if len(sps) == 0 || len(pps) == 0 {
		return
	}
	switch f := forma.(type) {
	case *format.H264:
		s.mu.Lock()
		same := bytes.Equal(f.SPS, sps) && bytes.Equal(f.PPS, pps)
		if !same {
			f.SPS, f.PPS = sps, pps
		}
		s.mu.Unlock()
		if same {
			return
		}
		if st != nil {
			st.ReloadDesc()
		}
		s.log.Info("rtsp: H.264 parameter sets updated for DESCRIBE", "profile_level", fmt.Sprintf("%x", sps[1:min(4, len(sps))]))
		if err := saveParams(s.cfg.ParamsFile, sps, pps); err != nil {
			s.log.Warn("rtsp: cannot persist H.264 parameter sets", "error", err)
		}
	case *format.H265:
		if len(vps) == 0 {
			return
		}
		s.mu.Lock()
		same := bytes.Equal(f.VPS, vps) && bytes.Equal(f.SPS, sps) && bytes.Equal(f.PPS, pps)
		if !same {
			f.VPS, f.SPS, f.PPS = vps, sps, pps
		}
		s.mu.Unlock()
		if same {
			return
		}
		if st != nil {
			st.ReloadDesc()
		}
		w, h := nal.Dimensions(nal.H265, sps)
		s.log.Info("rtsp: H.265 parameter sets updated for DESCRIBE", "largeur", w, "hauteur", h)
		if err := saveParamSets(s.cfg.ParamsFileH265, vps, sps, pps); err != nil {
			s.log.Warn("rtsp: cannot persist H.265 parameter sets", "error", err)
		}
	}
}

// loadParams reads SPS/PPS persisted by saveParams: two lines, base64.
func loadParams(path string) ([]byte, []byte, bool) {
	sets, ok := loadParamSets(path, 2)
	if !ok || len(sets[0]) < 4 || len(sets[1]) < 1 ||
		nalType(sets[0]) != nalTypeSPS || nalType(sets[1]) != nalTypePPS {
		return nil, nil, false
	}
	return sets[0], sets[1], true
}

// loadParamsH265 reads VPS/SPS/PPS persisted by saveParamSets: three
// lines, base64; the SPS must parse as H.265 (an H.264 file under this
// name, or a damaged one, is ignored).
func loadParamsH265(path string) (vps, sps, pps []byte, ok bool) {
	sets, ok := loadParamSets(path, 3)
	if !ok || nal.H265Type(sets[0]) != nal.H265VPS || nal.Detect(sets[1]) != nal.H265 || nal.H265Type(sets[2]) != nal.H265PPS {
		return nil, nil, nil, false
	}
	return sets[0], sets[1], sets[2], true
}

// loadParamSets reads n base64 lines from path.
func loadParamSets(path string, n int) ([][]byte, bool) {
	if path == "" {
		return nil, false
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, false
	}
	lines := strings.Fields(string(b))
	if len(lines) != n {
		return nil, false
	}
	sets := make([][]byte, n)
	for i, l := range lines {
		sets[i], err = base64.StdEncoding.DecodeString(l)
		if err != nil || len(sets[i]) == 0 {
			return nil, false
		}
	}
	return sets, true
}

// saveParams writes SPS/PPS atomically (temp file + rename).
func saveParams(path string, sps, pps []byte) error {
	return saveParamSets(path, sps, pps)
}

// saveParamSets writes parameter sets, one base64 line each, atomically
// (temp file + rename).
func saveParamSets(path string, sets ...[]byte) error {
	if path == "" {
		return nil
	}
	data := ""
	for _, set := range sets {
		data += base64.StdEncoding.EncodeToString(set) + "\n"
	}
	tmp := path + ".tmp"
	f, err := os.OpenFile(tmp, os.O_WRONLY|os.O_CREATE|os.O_TRUNC, 0o644)
	if err != nil {
		return err
	}
	if _, err := f.Write([]byte(data)); err != nil {
		f.Close()
		return err
	}
	if err := f.Sync(); err != nil {
		f.Close()
		return err
	}
	if err := f.Close(); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

// auHasParams reports whether the access unit already carries its
// parameter sets (SPS and PPS; VPS too in H.265), so we don't duplicate
// them.
func auHasParams(codec nal.Codec, au [][]byte) bool {
	var vps, sps, pps bool
	for _, n := range au {
		switch nal.Type(codec, n) {
		case paramTypeSPS(codec):
			sps = true
		case paramTypePPS(codec):
			pps = true
		case nal.H265VPS:
			vps = codec == nal.H265
		}
	}
	return sps && pps && (codec != nal.H265 || vps)
}

// audioEncoder turns the hub's PCM into AAC-LC RTP packets.
type audioEncoder struct {
	aac *aacenc.Stream
	rtp *rtpmpeg4audio.Encoder
}

func newAudioEncoder(f *format.MPEG4Audio) (*audioEncoder, error) {
	aac, err := aacenc.NewStream(aacenc.LC, audioRate, audioBitrate)
	if err != nil {
		return nil, err
	}
	enc := &rtpmpeg4audio.Encoder{
		PayloadType: f.PayloadTyp, SizeLength: f.SizeLength,
		IndexLength: f.IndexLength, IndexDeltaLength: f.IndexDeltaLength,
	}
	if err := enc.Init(); err != nil {
		aac.Close()
		return nil, err
	}
	return &audioEncoder{aac: aac, rtp: enc}, nil
}

func (a *audioEncoder) close() { a.aac.Close() }

// writeAudio encodes the PCM and writes it to the readers. An access
// unit's RTP timestamp comes from the PTS of its first sample, on the same
// hlcamd clock as the video.
func (s *Server) writeAudio(a *audioEncoder, sample camera.Sample) {
	err := a.aac.Write(sample.Data, sample.PTS, func(au []byte, pts int64) {
		pkts, err := a.rtp.Encode([][]byte{au})
		if err != nil {
			s.log.Warn("rtsp: aac packetize", "error", err)
			return
		}
		s.mu.Lock()
		st := s.stream
		s.mu.Unlock()
		if st == nil {
			return
		}
		ts := uint32(int64(s.randomStart) + pts*audioRate/90000)
		for _, p := range pkts {
			p.Timestamp = ts
			if err := st.WritePacketRTP(s.desc.Medias[1], p); err != nil {
				s.log.Warn("rtsp: audio write error", "error", err)
				return
			}
		}
	})
	if err != nil {
		s.log.Warn("rtsp: aac encode", "error", err)
	}
}
