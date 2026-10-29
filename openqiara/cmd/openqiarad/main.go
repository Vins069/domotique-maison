package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"log/slog"
	"net"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"github.com/caligone/openqiara/internal/alarm"
	"github.com/caligone/openqiara/internal/camera"
	"github.com/caligone/openqiara/internal/charmux"
	"github.com/caligone/openqiara/internal/config"
	"github.com/caligone/openqiara/internal/hlevents"
	"github.com/caligone/openqiara/internal/hlsserver"
	"github.com/caligone/openqiara/internal/mdns"
	"github.com/caligone/openqiara/internal/mediahub"
	"github.com/caligone/openqiara/internal/mqtt"
	"github.com/caligone/openqiara/internal/nal"
	"github.com/caligone/openqiara/internal/ota"
	"github.com/caligone/openqiara/internal/publisher"
	"github.com/caligone/openqiara/internal/qplus"
	"github.com/caligone/openqiara/internal/rtspserver"
	"github.com/caligone/openqiara/internal/videoparams"
	"github.com/caligone/openqiara/internal/web"
	staticweb "github.com/caligone/openqiara/web"
)

// Build-time variables injected via -ldflags. Stay as "dev" / "" when
// building locally without the release workflow.
//
//	go build -ldflags="-X main.version=v0.1.0-alpha.1 -X main.commit=abc1234 -X main.date=2026-05-15"
var (
	version = "dev"
	commit  = ""
	date    = ""
)

// BuildInfo returns the version string shown in /api/status and the
// -version output. Always non-empty.
func BuildInfo() string {
	s := version
	if commit != "" {
		s += " (" + commit
		if date != "" {
			s += ", " + date
		}
		s += ")"
	}
	return s
}

func main() {
	configPath := flag.String("config", "/data/openqiara.json", "path to config file")
	defaultsPath := flag.String("defaults", "/data/openqiara-defauts.json", "installation defaults, merged once into the config where it says nothing")
	settingsPath := flag.String("settings", "/data/openqiara-reglages.json", "settings change (reglage.sh), applied once over the config")
	webAddr := flag.String("web", ":80", "web UI listen address")
	debugAPI := flag.Bool("debug", false, "enable /api/v1/commands/debug/* endpoints (PKT raw, siren raw — can brick the MCU)")
	showVersion := flag.Bool("version", false, "print version and exit")
	// logPath="" → stdout (dev). Sinon, lumberjack écrit dans le fichier
	// avec rotation (cap dur, indispensable sur /data ~20 MB).
	logPath := flag.String("log", "", "path to log file with rotation; empty = stdout")
	logMaxMB := flag.Int("log-max-mb", 1, "max size per log file (MB) before rotation")
	logMaxBackups := flag.Int("log-max-backups", 3, "max number of rotated files to keep")
	logLevel := flag.String("log-level", "info", "debug, info, warn or error; debug traces every radio frame")
	flag.Parse()

	if *showVersion {
		fmt.Println(BuildInfo())
		os.Exit(0)
	}

	logWriter := newLogWriter(*logPath, *logMaxMB, *logMaxBackups)
	var level slog.Level
	if err := level.UnmarshalText([]byte(*logLevel)); err != nil {
		fmt.Fprintln(os.Stderr, "openqiarad:", err)
		os.Exit(2)
	}
	logger := slog.New(slog.NewTextHandler(logWriter, &slog.HandlerOptions{Level: level}))
	slog.SetDefault(logger)
	logger.Info("openqiarad starting", "version", BuildInfo(), "config", *configPath)

	store := config.NewStore(*configPath)
	if err := store.Load(); err != nil {
		logger.Error("failed to load config", "error", err)
		os.Exit(1)
	}
	// Installation defaults (OpenQIARA Claude V15 installer): merged once,
	// where the configuration says nothing, then the file is set aside.
	if set, err := store.ApplyDefaultsFile(*defaultsPath); err != nil {
		logger.Error("installation defaults not applied", "file", *defaultsPath, "error", err)
	} else if len(set) > 0 {
		logger.Info("installation defaults applied", "file", *defaultsPath, "fields", strings.Join(set, ","))
	}
	if set, err := store.ApplySettingsFile(*settingsPath); err != nil {
		logger.Error("settings change not applied", "file", *settingsPath, "error", err)
	} else if len(set) > 0 {
		logger.Info("settings change applied", "file", *settingsPath, "fields", strings.Join(set, ","))
	}
	cfg := store.Get()

	// The video codec: what hlcamd is asked for (video.codec,
	// read by camera_boot.sh too), checked against the stream's SPS by
	// the media hub. A mismatch is served as the stream is, logged, and
	// published at once (diagKick) rather than at the next minute.
	codecCfg, codecKnown := cfg.Video.VideoCodec()
	if !codecKnown {
		logger.Error("video.codec inconnu dans la configuration, H.264 utilisé", "valeur", cfg.Video.Codec)
	}
	codecState := nal.NewState(codecCfg, logger)
	diagKick := make(chan struct{}, 1)
	codecState.OnChange = func(nal.Codec) {
		select {
		case diagKick <- struct{}{}:
		default:
		}
	}
	logger.Info("video: codec configuré", "codec", codecCfg.String())

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()

	// openqiarad is the radio gateway: it takes the radio over from the MCU.
	cam := createCamera(ctx, store, logger)
	if cam == nil {
		logger.Error("no camera backend available")
		os.Exit(1)
	}
	defer func() { _ = cam.Close() }()

	sensors := cam.CachedSensors()
	logger.Info("sensors loaded", "count", len(sensors))
	for _, s := range sensors {
		logger.Info("sensor", "id", s.ID, "type", s.Type, "reachable", s.Reachable)
	}

	// Publishers (MQTT and/or HomeKit)
	var pubs []publisher.Publisher

	// alarmState est lu/écrit par 5 goroutines (handlers MQTT, alarm engine,
	// SSE callback, alarmo subscribe). atomic.Pointer évite la data race
	// constatée par -race avant 2026-05-15. Helpers définis pour ne pas
	// répéter le boilerplate Load()/Store() partout.
	var alarmStateBox atomic.Pointer[string]
	setAlarmState := func(s string) { alarmStateBox.Store(&s) }
	getAlarmState := func() string {
		if p := alarmStateBox.Load(); p != nil {
			return *p
		}
		return ""
	}
	// Empty until the alarm engine (standalone) or Alarmo sets it: a
	// "disarmed" default here was republished by OnConnect before the real
	// state loaded, a phantom disarm in HA at every boot (#58).

	// Command handler shared by all publishers
	cmds := &publisher.CommandHandler{
		OnAlarmCommand: func(state string) {
			logger.Info("alarm command", "state", state)
			setAlarmState(state)
			webSrvSetAlarm(state, pubs, ctx, logger)
		},
		OnShutterCommand: func(open bool) {
			logger.Info("shutter command from HomeKit", "open", open)
			if err := cam.SetShutter(ctx, open); err != nil {
				logger.Error("shutter command failed", "error", err)
			}
		},
		OnSirenCommand: func(sensorID int, on bool) {
			// Délégué à l'interface cam.Client.
			if on {
				logger.Info("siren command: wail", "sensor_id", sensorID)
				if err := cam.TriggerSirenAlarm(ctx, sensorID, store.Get().WailDuration()); err != nil {
					logger.Error("siren command failed", "error", err)
				}
			} else {
				logger.Info("siren command: stop", "sensor_id", sensorID)
				if err := cam.StopSiren(ctx, sensorID); err != nil {
					logger.Error("siren stop failed", "error", err)
				}
			}
		},
	}

	// Image settings: hlcamd's night exposure limits, day/night
	// threshold and the day image, read from its parameters file and written
	// through fbxbusctl within fixed bounds, as Home Assistant entities.
	// Served only when the file is there (a plain camera); read-only in
	// effect unless openqiara.json says "video": {"lock": false}.
	// Made before the MQTT publisher starts: whether the entities
	// are served, and the snapshot OnConnect republishes, are settled before
	// the first connection can read them.
	videoSvc := videoparams.New(logger)
	videoSvc.Lock = cfg.Video.Locked()
	videoServed := videoSvc.Available()
	videoSnapshot := videoSvc.Current

	// MQTT publisher
	var mqttPub *publisher.MQTTPublisher
	mqttConnected := func() bool { return mqttPub != nil && mqttPub.IsConnected() }
	if cfg.MQTT.Broker != "" {
		mqttCfg := mqtt.Config{
			Broker:        cfg.MQTT.Broker,
			Username:      cfg.MQTT.Username,
			Password:      cfg.MQTT.Password,
			TopicPrefix:   cfg.MQTT.TopicPrefix,
			TLSCACert:     cfg.MQTT.TLSCACert,
			TLSClientCert: cfg.MQTT.TLSClientCert,
			TLSClientKey:  cfg.MQTT.TLSClientKey,
			TLSInsecure:   cfg.MQTT.TLSInsecure,
		}
		if mqttCfg.TopicPrefix == "" {
			mqttCfg.TopicPrefix = "openqiara"
		}
		mqtt.SetCameraInfo(BuildInfo(), webURL("ssv0", *webAddr))
		mqttPub = publisher.NewMQTTPublisher(mqttCfg, logger)
		mqttPub.HAPublisher().SetVideoParams(videoServed)
		if videoServed {
			ha := mqttPub.HAPublisher()
			videoSvc.OnChange = func(s videoparams.Snapshot) {
				if err := ha.PublishVideoState(ctx, s); err != nil {
					logger.Debug("video state not published", "error", err)
				}
			}
		}
		// In alarmo mode, don't publish our own alarm_control_panel entity —
		// Alarmo is the source of truth for the alarm state in HA.
		mqttPub.PublishAlarmEntity = cfg.AlarmMode() == "standalone"

		// Re-pushed on every (re)connect so HA recovers after a broker/HA
		// restart without a daemon reboot.
		mqttPub.HAPublisher().SetOnConnect(func() {
			republishSensorStates(ctx, cam.CachedSensors(), mqttPub.PublishSensorState, logger)
			// The camera's own detection entities, published or removed.
			if err := mqttPub.HAPublisher().SyncIVEntities(ctx, ivDetectionWanted(store.Get().Video, hlcamdOptionsPath)); err != nil {
				logger.Warn("mqtt: IV entities not synced on connect", "error", err)
			}
			if err := mqttPub.HAPublisher().PublishShutterState(ctx, !store.Get().ShutterClosed); err != nil {
				logger.Warn("republish shutter state on connect failed", "error", err)
			}
			// The image settings as last read: their retained
			// state may be gone with the broker's.
			if s, ok := videoSnapshot(); ok {
				if err := mqttPub.HAPublisher().PublishVideoState(ctx, s); err != nil {
					logger.Warn("republish video state on connect failed", "error", err)
				}
			}
			// The night-vision wish, kept in the config, not read
			// from hlcamd's file.
			if videoServed {
				if err := mqttPub.HAPublisher().PublishNightVision(ctx, store.Get().Video.NightVisionWish()); err != nil {
					logger.Warn("republish night vision on connect failed", "error", err)
				}
			}
			// Republish the current alarm state too, so HA recovers the real
			// state after a broker/HA restart that dropped the retained value.
			// Standalone only — in alarmo mode HA Alarmo owns the panel and we
			// don't publish a standalone alarm entity. See #29.
			if store.Get().AlarmMode() == "standalone" {
				if st := getAlarmState(); st != "" {
					if err := mqttPub.PublishAlarmState(ctx, st); err != nil {
						logger.Warn("republish alarm state on connect failed", "error", err)
					}
				}
			}
		})

		// Start no longer fails on an unreachable broker: paho reconnects in the
		// background and re-publishes discovery + state via OnConnect.
		if err := mqttPub.Start(ctx, sensors, cmds); err != nil {
			logger.Error("failed to start MQTT publisher", "error", err)
		} else {
			pubs = append(pubs, mqttPub)
			logger.Info("MQTT publisher started", "broker", cfg.MQTT.Broker)

			// Setup shutter command handler
			mqttPub.HAPublisher().SetupShutterCommandHandler(func(open bool) {
				if err := cam.SetShutter(ctx, open); err != nil {
					logger.Warn("shutter command failed", "error", err)
				}
			}, logger)
			// Qiara Plus: Home Assistant's buttons leave orders for the guard
			// (absent: its entities left by an earlier version are removed).
			mqttPub.HAPublisher().SetQPlusInstalled(qplus.Default.Installed())
			if qplus.Default.Installed() {
				mqttPub.HAPublisher().SetupQPlusCommandHandler(qplus.Default.Order, logger)
			}
		}
	} else {
		logger.Warn("no MQTT broker configured")
	}

	// The image settings' commands and reads, once the MQTT client exists.
	if mqttPub != nil {
		ha := mqttPub.HAPublisher()
		if videoServed {
			ha.SetupVideoCommandHandler(ctx, videoSvc, logger)
			ha.SetupNightVisionHandler(ctx, nightVisionSetter{store: store, cam: cam, ha: ha, log: logger}, logger)
			go videoSvc.Run(ctx, time.Minute)
			logger.Info("image settings served", "file", videoSvc.File, "lock", videoSvc.Lock)
		} else {
			logger.Info("image settings not served: hlcamd's parameters file absent", "file", videoSvc.File)
		}
	}

	// Shared media pipeline: hlcamd's 1080p stream and microphone, read
	// once from the loopback multicast and fanned out to HomeKit (SRTP),
	// RTSP and the HLS of /stream/. hlcamd freezes silently after a few
	// hours (feedback_hlcamd_freeze_after_hours.md): the resumer wakes it
	// when the hub's samples stop.
	var mediaHub *mediahub.Hub
	hlcamdResumer := camera.NewHlcamdResumer(func() time.Time { return mediaHub.LastSample() }, 10*time.Second, 5*time.Second, logger)
	mediaHub = mediahub.New("multicast 1080p + audio", mediahub.Multicast(camera.MulticastVideoMain, camera.MulticastAudio, logger), hlcamdResumer, logger)
	mediaHub.SetCodecState(codecState)
	hlsSrv := hlsserver.New(mediaHub, true, logger)
	hlsSrv.SetCodecState(codecState)

	go func() {
		select {
		case <-time.After(10 * time.Second): // hlcamd registers on fbxbus
			hlcamdResumer.Shutter(ctx, !store.Get().ShutterClosed)
		case <-ctx.Done():
		}
	}()
	// The codec probe: once hlcamd is up and resumed, the
	// stream is read until its SPS says its codec, so that a video.codec
	// at odds with what hlcamd makes is known, logged and published before
	// the first client comes. Nothing to read behind a closed shutter: the
	// first viewing settles it then.
	go func() {
		select {
		case <-time.After(codecProbeAfter):
		case <-ctx.Done():
			return
		}
		if store.Get().ShutterClosed {
			logger.Info("video: codec non sondé au démarrage, volet fermé", "configure", codecState.Configured().String())
			return
		}
		if c := mediaHub.ProbeCodec(ctx, codecProbeFor); c == nal.Unknown {
			logger.Warn("video: codec non confirmé au démarrage, aucun SPS reçu", "configure", codecState.Configured().String())
		}
	}()

	// HomeKit publisher
	var hkPub *publisher.HomeKitPublisher
	if cfg.HomeKit.Enabled {
		hkPub = publisher.NewHomeKitPublisher(publisher.HomeKitConfig{
			Pin:  cfg.HomeKit.Pin,
			Name: cfg.HomeKit.Name,
			// Don't expose our SecuritySystem when Alarmo already exposes one
			// via HA's HomeKit integration — avoids showing 2 alarm panels.
			ExposeAlarm: cfg.AlarmMode() != "alarmo",
			Camera: publisher.CameraConfig{
				Enabled: homekitCameraEnabled(cfg.HomeKit.Camera.Enabled, codecCfg, logger),
				Name:    cfg.HomeKit.Camera.Name,
			},
		}, logger)
		hkPub.PublishShutterState(!store.Get().ShutterClosed)
		if err := hkPub.Start(ctx, sensors, cmds); err != nil {
			logger.Error("failed to start HomeKit publisher", "error", err)
		} else {
			pubs = append(pubs, hkPub)
			logger.Info("HomeKit publisher started")
		}
	}

	// The video pipeline follows the privacy shutter (#50): paused while
	// closed, at start too. hlcamd starts paused; this replaces the
	// resume_streams boot.sh sent. HA and HomeKit follow it too, whoever
	// moved it.
	if rc, ok := cam.(*camera.RadioClient); ok {
		rc.OnShutter = func(ctx context.Context, open bool) {
			if err := store.Update(func(c *config.Config) { c.ShutterClosed = !open }); err != nil {
				logger.Warn("shutter state not saved", "error", err)
			}
			hlcamdResumer.Shutter(ctx, open)
			// The shutter set hlcamd's day/night mode: the image settings
			// read it again soon rather than at the next minute.
			videoSvc.Kick()
			if mqttPub != nil {
				if err := mqttPub.HAPublisher().PublishShutterState(ctx, open); err != nil {
					logger.Warn("publish shutter state failed", "error", err)
				}
			}
			if hkPub != nil {
				hkPub.PublishShutterState(open)
			}
		}
	}

	// RTSP server — standard H.264 + AAC-LC stream for Scrypted/Frigate/VLC.
	if cfg.RTSP.Enabled {
		listen := cfg.RTSP.Listen
		if listen == "" {
			listen = ":8554"
		}
		rtspSrv := rtspserver.New(rtspserver.Config{
			Listen:         listen,
			Path:           cfg.RTSP.Path,
			Audio:          true,
			ParamsFile:     filepath.Join(filepath.Dir(*configPath), "openqiara_rtsp_h264_params"),
			ParamsFileH265: filepath.Join(filepath.Dir(*configPath), "openqiara_rtsp_h265_params"),
		}, mediaHub, logger)
		rtspSrv.SetCodecState(codecState)
		if err := rtspSrv.Start(ctx); err != nil {
			logger.Error("failed to start RTSP server", "error", err)
		} else {
			logger.Info("RTSP server started", "listen", listen)
		}
	}

	// Web UI
	mqttCB := &web.MQTTCallbacks{
		OnSensorRenamed: func(ctx context.Context, sensor camera.Sensor) error {
			if mqttPub == nil {
				return nil
			}
			hp := mqttPub.HAPublisher()
			if err := hp.PublishDiscovery(ctx, sensor); err != nil {
				return err
			}
			for _, extra := range mqtt.BuildExtraDiscoveryTopics(hp.Prefix(), sensor) {
				_ = hp.PublishRaw(ctx, extra.Topic, extra.Payload)
			}
			return nil
		},
		OnSensorDeleted: func(ctx context.Context, sensorID int) error {
			if mqttPub == nil {
				return nil
			}
			return mqttPub.HAPublisher().RemoveDiscovery(ctx, sensorID)
		},
		OnSensorsChanged: func(ctx context.Context) {
			// Rebuild HomeKit bridge so newly paired sensors appear and
			// removed sensors disappear. AIDs are derived from sensor.ID
			// so existing accessories survive the rebuild.
			if hkPub == nil {
				return
			}
			if err := hkPub.RebuildBridge(cam.CachedSensors()); err != nil {
				logger.Warn("homekit rebuild failed", "error", err)
			}
		},
		OnAlarmStateChanged: func(ctx context.Context, state string) error {
			setAlarmState(state)
			for _, p := range pubs {
				if err := p.PublishAlarmState(ctx, state); err != nil {
					logger.Warn("publish alarm state failed", "error", err)
				}
			}
			return nil
		},
	}
	var webSrv *web.Server
	if cfg.WebEnabled() {
		webSrv = web.NewServer(cam, store, mqttConnected, mqttCB, staticweb.StaticFiles, logger)
		webSrv.SetVersion(BuildInfo())
		if *debugAPI {
			webSrv.EnableDebugEndpoints()
			logger.Warn("debug API endpoints enabled — DO NOT use in production")
		}
		webSrv.SetSensorCount(len(sensors))
		if err := webSrv.Start(*webAddr); err != nil {
			logger.Error("failed to start web server", "error", err)
			os.Exit(1)
		}
		defer func() {
			// Shutdown avec timeout : sans ça, les connexions SSE ouvertes
			// (clients UI temps réel) bloquent indéfiniment et killall finit
			// par avoir 2 instances qui se battent pour le port HK.
			shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			_ = webSrv.Shutdown(shutdownCtx)
		}()

		// mDNS announce: openqiara.local on the web port.
		if port := parseListenPort(*webAddr); port > 0 {
			go func() {
				if err := mdns.Announce(ctx, port, logger); err != nil && ctx.Err() == nil {
					logger.Warn("mdns announce failed", "error", err)
				}
			}()
		}
	} else {
		logger.Info("web server disabled in config (headless mode)")
	}

	// hl_event_collectd → MQTT dispatcher (IntelliVision detections).
	//
	// hlcamd remet ses détections IV (human/pet) à hl_event_collectd sur
	// fbxbus, nom qu'openqiarad tient (event_collector.go) : on les
	// transforme en états binary_sensor MQTT pour Home Assistant.
	//
	// Le dispatcher maintient un état par object_id avec auto-expire après
	// 30s sans Exit/Lost (au cas où la cam perd l'objet en cours). Le sink
	// reçoit chaque transition et publie sur MQTT.
	ivWanted := ivDetectionWanted(store.Get().Video, hlcamdOptionsPath)
	if mqttPub != nil && !ivWanted {
		// Detection turned off for good (/data/hlcamd_options): its two
		// entities are removed rather than left "off" forever.
		// Not connected yet (the usual case at start): the connection's own
		// handler removes them, a try here would only time out.
		if mqttPub.HAPublisher().LinkUp() {
			if err := mqttPub.HAPublisher().SyncIVEntities(ctx, false); err != nil {
				logger.Warn("mqtt: IV entities not removed", "error", err)
			}
		}
	} else if mqttPub != nil {
		// Publish discovery une fois (HA va auto-créer les entités).
		if err := mqttPub.HAPublisher().PublishIVDiscovery(ctx); err != nil {
			logger.Warn("mqtt: publish IV discovery failed", "error", err)
		}
		// État initial false sur les deux topics — sans ça HA garde
		// "unknown" tant qu'aucune détection de cette classe n'est jamais
		// arrivée, ce qui est moche dans le dashboard.
		for _, kind := range []string{"human", "pet"} {
			if err := mqttPub.HAPublisher().PublishIVDetection(ctx, kind, false, 0, ""); err != nil {
				logger.Warn("mqtt: publish IV initial state failed", "kind", kind, "error", err)
			}
		}
	}
	if mqttPub != nil {
		go serveDiagnostics(ctx, mqttPub, cam, BuildInfo(), codecState, mediaHub, diagKick, logger)
	}
	// The camera's HomeKit motion sensor (HomeKit Secure Video's trigger)
	// is on while anyone, person or pet, is in sight.
	var hkCam *publisher.HomeKitCamera
	if hkPub != nil {
		hkCam = hkPub.Camera()
	}
	var inSightMu sync.Mutex
	inSight := map[string]bool{}
	ivDispatcher := hlevents.NewDispatcher(logger, func(det hlevents.Detection) {
		kind := "human"
		if det.Class == hlevents.IVClassPet {
			kind = "pet"
		} else if det.Class != hlevents.IVClassHuman {
			// Classe inconnue (jamais observée en live) : skip.
			return
		}
		// Turned off for good: hlcamd still runs with the vendor's settings
		// (detection on) the first 90 s after a boot, and its detections
		// would bring back the removed entities' states.
		if mqttPub != nil && ivWanted {
			if err := mqttPub.HAPublisher().PublishIVDetection(ctx, kind, det.Present, det.Confidence, det.ObjectID); err != nil {
				logger.Warn("mqtt: publish IV detection failed",
					"kind", kind, "present", det.Present, "error", err)
			}
		}
		if hkCam != nil {
			inSightMu.Lock()
			if det.Present {
				inSight[det.ObjectID] = true
			} else {
				delete(inSight, det.ObjectID)
			}
			// Under the lock: sinks run in their own goroutines, and a
			// late SetMotion(true) would leave the sensor stuck.
			hkCam.SetMotion(len(inSight) > 0)
			inSightMu.Unlock()
		}
	}, 30*time.Second)
	go serveEventCollector(ctx, ivDispatcher, logger)

	// hlcamdResumer + mediaHub sont créés plus haut (avant HomeKit/RTSP).
	// On les branche ici sur les consommateurs dont le handle n'existe
	// qu'après Start (web UI, caméra HK).
	if webSrv != nil {
		webSrv.SetHlcamdResumer(hlcamdResumer)
		webSrv.SetHLS(hlsSrv)
	}
	if hkPub != nil && hkPub.Camera() != nil {
		hkPub.Camera().SetCodecState(codecState)
		hkPub.Camera().SetMediaHub(mediaHub)
	}

	// OTA updater — interroge GitHub Releases pour proposer des
	// updates depuis l'UI.
	//
	// onComplete : on NE swappe PAS le binaire à chaud. Le process courant
	// tient /data/openqiarad par inode (rm ne libère pas l'espace tant
	// qu'on vit) et /data est trop plein pour deux binaires. On dépose donc
	// un marqueur ota_pending (chemin du binaire staged) et on reboote :
	// boot.sh applique le swap au démarrage suivant, FD libre et espace
	// dispo. Plus robuste qu'un SIGTERM + relance (qui dépendait d'un
	// shutdown propre et d'un re-bind du port :80).
	if webSrv != nil {
		otaClient := ota.NewClient(BuildInfo(), logger)
		cfg := ota.DefaultInstallConfig()
		var otaInstaller *ota.Installer
		otaInstaller = ota.NewInstaller(otaClient, cfg, func() {
			staged := otaInstaller.Status().StagedAt
			if staged == "" {
				logger.Error("OTA onComplete: no staged path — aborting swap")
				return
			}
			if err := os.WriteFile(ota.PendingMarkerPath, []byte(staged+"\n"), 0644); err != nil {
				logger.Error("OTA: write pending marker failed", "error", err)
				return
			}
			logger.Info("OTA staged — rebooting to apply", "staged", staged)
			time.Sleep(500 * time.Millisecond) // laisse l'UI poller le status final
			_ = exec.Command("reboot").Run()
		})
		webSrv.SetOTA(otaClient, otaInstaller)
	}

	// Alarm engine — standalone state machine for arm/disarm/triggered logic.
	// Config provider reads night_mode from the config store on each query.
	// alarmConfigFor mappe la config sensor vers le format attendu par
	// l'engine : NightAllowed = capteur ignoré en mode nuit, Instant = pas
	// de délai d'entrée.
	alarmConfigFor := func(sensorID int) alarm.SensorConfig {
		for _, se := range store.Get().Sensors {
			if se.ID == sensorID {
				return alarm.SensorConfig{NightAllowed: se.NightAllowed, Instant: se.Instant}
			}
		}
		return alarm.SensorConfig{}
	}
	// The siren keeps the alarm (internal/alarm): the standalone engine
	// drives it, and in alarmo mode sirenCtrl mirrors Alarmo's state on it.
	siren := alarm.NewSirenDriver(nativeSiren{ctx: ctx, cam: cam, store: store}, logger)
	sirenCtrl := newSirenController(ctx, siren)

	alarmStateCallback := func(snap alarm.Snapshot) {
		logger.Info("alarm state", "state", snap.State, "prev", snap.PreviousState, "trigger", snap.TriggeredBy, "remaining", snap.TimerRemaining)
		setAlarmState(string(snap.State))
		if webSrv == nil {
			for _, p := range pubs {
				_ = p.PublishAlarmState(ctx, string(snap.State))
			}
			return
		}
		webSrv.SetAlarmState(string(snap.State))
		// Push to SSE clients immediately (don't wait for the next tick).
		webSrv.PublishEvent("alarm", web.AlarmSnapshot{
			State:          string(snap.State),
			ArmedAt:        snap.ArmedAt,
			TriggeredBy:    snap.TriggeredBy,
			PreviousState:  string(snap.PreviousState),
			TimerRemaining: snap.TimerRemaining,
		})
		for _, p := range pubs {
			_ = p.PublishAlarmState(ctx, string(snap.State))
		}
	}
	// Only spin up the local alarm engine in standalone mode. In alarmo
	// mode HA Alarmo is the source of truth and the engine would just
	// shadow its state, causing drift and useless persistence churn.
	var alarmEngine *alarm.Engine
	if store.Get().AlarmMode() == "standalone" {
		alarmEngine = alarm.New("/data/openqiara_alarm.json", siren, alarmConfigFor, alarmStateCallback, logger)
		cfg := store.Get()
		alarmEngine.SetTimings(cfg.ArmingDelay(), cfg.PendingDelay())
		if err := alarmEngine.Load(); err != nil {
			logger.Warn("alarm: load failed, starting fresh", "error", err)
		}
		if webSrv != nil {
			webSrv.SetAlarmProvider(&alarmAdapter{eng: alarmEngine})
			webSrv.SetAlarmState(string(alarmEngine.Snapshot().State))
		}
		initSnap := alarmEngine.Snapshot()
		setAlarmState(string(initSnap.State))
		// Push the restored state to every publisher. Load() restores the
		// state without firing onChange, and MQTT's Start() publishes a
		// hard "disarmed" retained at discovery — so without this, HA/HomeKit
		// keep showing disarmed after a reboot even though the alarm is armed
		// (or triggered). This overwrites that stale retained value. See #29.
		for _, p := range pubs {
			if err := p.PublishAlarmState(ctx, string(initSnap.State)); err != nil {
				logger.Warn("publish restored alarm state failed", "error", err)
			}
		}
		logger.Info("alarm engine started", "state", initSnap.State)
	} else {
		logger.Info("alarm engine skipped (alarmo mode — HA Alarmo is the source of truth)")
	}

	// dispatchAlarmCommand routes a user alarm command (from web, HomeKit, MQTT or KPD)
	// according to the current config:
	//   - mode "standalone": feed the local alarm.Engine
	//   - mode "alarmo":     forward to alarmo/command MQTT topic (no local engine)
	// `source` qualifie l'origine : SourceLocal (KPD physique = délai armement
	// appliqué) vs SourceRemote (HK/web/MQTT = armement immédiat, sinon un intrus
	// aurait 60s pour fuir après alerte distante).
	// Config is re-read on every call so mode switches take effect at runtime.
	dispatchAlarmCommand := func(cmd string, source alarm.Source) {
		// Normalise "ARM_AWAY"/"armed_away" → "arm_away" etc.
		switch cmd {
		case "disarmed", "DISARM":
			cmd = "disarm"
		case "armed_away", "ARM_AWAY":
			cmd = "arm_away"
		case "armed_night", "ARM_NIGHT":
			cmd = "arm_night"
		}
		if cmd != "disarm" && cmd != "arm_away" && cmd != "arm_night" {
			return
		}

		cfg := store.Get()
		if cfg.AlarmMode() == "alarmo" {
			topic, _ := cfg.AlarmoTopics()
			var payload string
			switch cmd {
			case "arm_away":
				payload = "ARM_AWAY"
			case "arm_night":
				payload = "ARM_NIGHT"
			case "disarm":
				payload = "DISARM"
			}
			if mqttPub != nil {
				// PublishCommand, not PublishRaw: a retained ARM_AWAY is
				// replayed to Alarmo every time it reconnects, so it would
				// re-arm from a stale command after each HA restart.
				if err := mqttPub.HAPublisher().PublishCommand(ctx, topic, []byte(payload)); err != nil {
					logger.Warn("alarmo command publish failed", "topic", topic, "error", err)
				} else {
					logger.Info("alarm command → alarmo", "topic", topic, "payload", payload, "source", source)
				}
			}
			return
		}
		// standalone: feed the local engine.
		logger.Info("alarm command → engine", "cmd", cmd, "source", source)
		if alarmEngine != nil {
			alarmEngine.HandleCommand(cmd, source)
		}
	}

	// Wire up alarm commands from publishers (MQTT/HomeKit) to the dispatcher.
	// MQTT et HomeKit = sources distantes (skip délai d'armement).
	cmds.OnAlarmCommand = func(cmd string) { dispatchAlarmCommand(cmd, alarm.SourceRemote) }
	mqttCB.OnAlarmCommand = func(_ context.Context, cmd string) {
		dispatchAlarmCommand(cmd, alarm.SourceRemote)
	}

	// Subscribe to alarmo/state to reflect Alarmo's state in our UI when in
	// alarmo mode. We subscribe unconditionally so mode can be switched at
	// runtime. The handler only acts if current mode is "alarmo".
	if mqttPub != nil {
		_, alarmoStateTopic := store.Get().AlarmoTopics()
		mqttPub.HAPublisher().Subscribe(alarmoStateTopic, func(topic string, payload []byte) {
			if store.Get().AlarmMode() != "alarmo" {
				return
			}
			state := string(payload)
			prev := getAlarmState()
			logger.Info("alarmo state received", "state", state, "prev", prev)
			if webSrv != nil {
				webSrv.SetAlarmState(state)
				webSrv.PublishEvent("alarm", web.AlarmSnapshot{State: state})
			}
			for _, p := range pubs {
				_ = p.PublishAlarmState(ctx, state)
			}
			sirenCtrl.Handle(state)
			setAlarmState(state)
		})
	}

	// Ensure publishers are closed on exit
	defer func() {
		for _, p := range pubs {
			_ = p.Close()
		}
	}()

	// The siren's reports: the driver brings the siren back to the state
	// wanted, and in standalone mode they move the alarm on.
	onSirenState := func(state string) {
		siren.HandleReport(alarm.SirenState(state))
		if alarmEngine != nil && store.Get().AlarmMode() == "standalone" {
			alarmEngine.HandleSirenState(alarm.SirenState(state))
		}
	}

	// The MCU's hardware watchdog, fed while openqiarad is healthy: the
	// gateway and the alarm answer (each check takes their lock) and the
	// radio is alive. hlcamd is not part of it: a camera whose
	// video pipeline died must not restart every 5 to 6 min and cut the
	// alarm's radio each time; Qiara Plus's guard watches hlcamd and
	// restarts the camera, within its own budget, when it stays gone. The
	// same check feeds Qiara Plus's health record (/tmp/qp/health, every
	// 10 s), read by the guard.
	appHealth := func() error { return errors.New("no radio gateway") }
	if rc, ok := cam.(*camera.RadioClient); ok {
		appHealth = func() error {
			if alarmEngine != nil {
				alarmEngine.Snapshot()
			}
			return rc.RadioHealth()
		}
		wd := newMCUWatchdog(appHealth, logger)
		go wd.run(ctx)
	}
	go qplus.Default.RunHealth(ctx, 10*time.Second, func() qplus.Health {
		err := appHealth()
		h := qplus.Health{OK: err == nil, Version: BuildInfo()}
		if err != nil {
			h.Err = err.Error()
		}
		if mqttPub != nil {
			// LinkUp, not IsConnected: no lock (a publish stuck under the
			// publisher's lock must not age the record) and false while
			// paho retries (IsConnected stays true then).
			h.MQTTConf, h.MQTT = true, mqttPub.HAPublisher().LinkUp()
			h.BrokerKnown, h.BrokerUp = mqttPub.HAPublisher().BrokerReachable()
		}
		return h
	})

	forwardEvents(ctx, cam, pubs, webSrv, alarmEngine, store, dispatchAlarmCommand, onSirenState, logger)
}

// Timing of the codec probe at start: after hlcamd's resume (10 s after
// the start), for as long as a GOP and some (the SPS comes with each key
// picture, every 2 s on the camera).
const (
	codecProbeAfter = 12 * time.Second
	codecProbeFor   = 20 * time.Second
)

// homekitCameraEnabled tells whether the HomeKit camera accessory is
// published: not when video.codec asks hlcamd for H.265, which
// HomeKit (RFC 6184 live stream) and HomeKit Secure Video (fMP4 avc1)
// cannot take. The refusal is logged as an error: the setting, not the
// camera, is what to change (docs/video.md). A stream that turns out to
// be H.265 despite an H.264 setting is refused session by session.
func homekitCameraEnabled(enabled bool, codec nal.Codec, logger *slog.Logger) bool {
	if enabled && codec != nal.H264 {
		logger.Error("homekit: accessoire caméra non publié : HomeKit et HomeKit Secure Video n'acceptent que le H.264",
			"video_codec", codec.String())
		return false
	}
	return enabled
}

// nightVisionSetter applies the night-vision select from Home Assistant:
// it saves the wish in the config, applies it at once if the
// shutter is open, and republishes the select's state.
type nightVisionSetter struct {
	store *config.Store
	cam   camera.Client
	ha    *mqtt.HAPublisher
	log   *slog.Logger
}

func (n nightVisionSetter) SetNightVision(ctx context.Context, wish string) error {
	if err := n.store.Update(func(c *config.Config) { c.Video.NightVision = wish }); err != nil {
		return err
	}
	// Applied now only while the shutter is open; otherwise it waits for the
	// next open (ApplyNightVision is a no-op while closed). A failure to
	// apply does not lose the wish — it is saved, and the shutter re-applies
	// it on the next open.
	if err := n.cam.ApplyNightVision(ctx); err != nil {
		n.log.Warn("night vision saved but not applied now", "wish", wish, "error", err)
	}
	return n.ha.PublishNightVision(ctx, wish)
}

// createCamera makes openqiarad the radio gateway. It fails while
// another process holds the charmux ports.
func createCamera(ctx context.Context, store *config.Store, logger *slog.Logger) camera.Client {
	c := camera.NewRadioClient(charmux.New(charmux.WithLogger(logger)), store, logger)
	if err := c.Connect(ctx); err != nil {
		logger.Error("radio gateway unavailable", "error", err)
		return nil
	}
	return c
}

// webSrvSetAlarm updates the web server alarm state and publishes to all publishers.
func webSrvSetAlarm(state string, pubs []publisher.Publisher, ctx context.Context, logger *slog.Logger) {
	for _, p := range pubs {
		if err := p.PublishAlarmState(ctx, state); err != nil {
			logger.Error("publish alarm state failed", "error", err)
		}
	}
}

// republishSensorStates pushes the sensors' live state on an MQTT
// (re)connect. A keypad has no state; nor does a door or motion sensor
// before its first report since the start: the state retained for it on
// the broker, which Home Assistant reads back after its own restart,
// stays.
func republishSensorStates(ctx context.Context, sensors []camera.Sensor, publish func(context.Context, camera.Sensor) error, logger *slog.Logger) {
	for _, s := range sensors {
		// A keypad has no state of its own, only its battery, reachability
		// and temperature: always republished, or Home Assistant
		// shows them unknown until its battery level changes, which is never.
		if s.Type != "KPD" && !s.StateKnown() {
			continue
		}
		if err := publish(ctx, s); err != nil {
			logger.Warn("publish sensor state failed", "id", s.ID, "error", err)
		}
	}
}

// logSensorEvent only logs state fields that are meaningful for the sensor
// type: a PIR has no open/closed state.
func logSensorEvent(logger *slog.Logger, evt camera.SensorEvent, source string) {
	attrs := []any{
		"id", evt.SensorID,
		"type", evt.Sensor.Type,
	}
	switch evt.Sensor.Type {
	case "DWS":
		attrs = append(attrs, "open", evt.Sensor.Open)
	case "PIR":
		attrs = append(attrs, "motion", evt.Sensor.Motion)
	}
	attrs = append(attrs, "battery", evt.Sensor.Battery)
	if source != "" {
		attrs = append(attrs, "src", source)
	}
	logger.Info("sensor event", attrs...)
}

func forwardEvents(
	ctx context.Context,
	cam camera.Client,
	pubs []publisher.Publisher,
	webSrv *web.Server,
	alarmEngine *alarm.Engine,
	store *config.Store,
	dispatchCmd func(cmd string, source alarm.Source),
	onSirenState func(state string),
	logger *slog.Logger,
) {
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, syscall.SIGINT, syscall.SIGTERM)

	for {
		select {
		case evt, ok := <-cam.Events():
			if !ok {
				return
			}
			if evt.Notice != "" {
				// A tamper, an emergency key or a reboot: a Home Assistant
				// event, nothing for the alarm engine to decide here.
				logger.Warn("sensor notice", "id", evt.SensorID, "type", evt.Sensor.Type, "notice", evt.Notice)
				for _, p := range pubs {
					if np, ok := p.(interface {
						PublishNotice(context.Context, camera.Sensor, string) error
					}); ok {
						if err := np.PublishNotice(ctx, evt.Sensor, evt.Notice); err != nil {
							logger.Error("publish notice failed", "error", err)
						}
					}
				}
				continue
			}
			if evt.Sensor.Type == "KPD" && evt.Sensor.KPDState != "" {
				action := evt.Sensor.KPDState
				logger.Info("KPD command", "id", evt.SensorID, "action", action)
				// KPD physique → source locale, délai d'armement appliqué.
				dispatchCmd(action, alarm.SourceLocal)
			} else {
				logSensorEvent(logger, evt, "")
				// Publish to MQTT/HomeKit regardless of alarm mode — sensors are
				// always exposed as binary_sensors so Alarmo (or any other
				// consumer) can react to them.
				for _, p := range pubs {
					if err := p.PublishSensorState(ctx, evt.Sensor); err != nil {
						logger.Error("publish sensor failed", "error", err)
					}
				}
				// Push the single-sensor update to SSE clients (no MCU call).
				if webSrv != nil {
					webSrv.PublishEvent("sensor", evt.Sensor)
				}
				if evt.SirenReport {
					onSirenState(evt.Sensor.SirenState)
				}
				// Only feed the local alarm engine in standalone mode.
				// In alarmo mode, Alarmo has its own trigger logic via HA.
				if alarmEngine != nil && store.Get().AlarmMode() == "standalone" {
					inAlarm := sensorInAlarm(evt.Sensor)
					alarmEngine.HandleSensorEvent(evt.SensorID, evt.Sensor.Type, inAlarm)
				}
			}
		case <-sig:
			logger.Info("shutting down")
			return
		}
	}
}

// parseListenPort extracts the numeric port from a listen address like ":8080" or "0.0.0.0:80".
func parseListenPort(addr string) int {
	// Simple split: take the last colon-separated token.
	i := len(addr) - 1
	for i >= 0 && addr[i] != ':' {
		i--
	}
	if i < 0 || i == len(addr)-1 {
		return 0
	}
	n := 0
	for _, c := range addr[i+1:] {
		if c < '0' || c > '9' {
			return 0
		}
		n = n*10 + int(c-'0')
	}
	return n
}

// alarmAdapter bridges alarm.Engine to web.AlarmProvider.
type alarmAdapter struct {
	eng *alarm.Engine
}

func (a *alarmAdapter) Snapshot() web.AlarmSnapshot {
	s := a.eng.Snapshot()
	return web.AlarmSnapshot{
		State:          string(s.State),
		ArmedAt:        s.ArmedAt,
		TriggeredBy:    s.TriggeredBy,
		PreviousState:  string(s.PreviousState),
		TimerRemaining: s.TimerRemaining,
	}
}

// HandleCommand est appelé uniquement depuis le handler web fallback (quand
// le dispatcher MQTT n'est pas câblé). Source = remote (HTTP).
func (a *alarmAdapter) HandleCommand(cmd string) { a.eng.HandleCommand(cmd, alarm.SourceRemote) }

func (a *alarmAdapter) SetTimings(arming, pending time.Duration) {
	a.eng.SetTimings(arming, pending)
}

// sensorInAlarm returns true if the sensor is currently in its "alarm" state,
// i.e. open door or motion detected.
func sensorInAlarm(s camera.Sensor) bool {
	switch s.Type {
	case "DWS":
		return s.Open
	case "PIR":
		return s.Motion
	case "SRN":
		// A siren is an actuator: it never triggers the alarm by itself.
		// DomusRF sensors expose no usable tamper state (see issue #30).
		return false
	default:
		return false
	}
}

// webURL is the web interface's address on the camera's Wi-Fi (for Home
// Assistant's "visit" link), or "" when the interface has no IPv4 yet.
func webURL(iface, listen string) string {
	ifc, err := net.InterfaceByName(iface)
	if err != nil {
		return ""
	}
	addrs, err := ifc.Addrs()
	if err != nil {
		return ""
	}
	_, port, _ := net.SplitHostPort(listen)
	for _, a := range addrs {
		if ipn, ok := a.(*net.IPNet); ok && ipn.IP.To4() != nil {
			if port == "" || port == "80" {
				return "http://" + ipn.IP.String() + "/"
			}
			return "http://" + net.JoinHostPort(ipn.IP.String(), port) + "/"
		}
	}
	return ""
}
