package web

import (
	"encoding/json"
	"github.com/caligone/openqiara/internal/qplus"
	"net/http"
	"strings"
)

// handleUpdateCheck interroge l'API GitHub (cache 1h) et retourne les
// infos de la dernière release. ?force=1 contourne le cache.
//
// Réponse :
//
//	{
//	  "current": "v0.1.0-alpha.1 (abc1234, ...)",
//	  "latest": { "tag_name": "v0.1.0-alpha.2", "body": "...", ... },
//	  "update_needed": true,
//	  "checked_at": "2026-05-15T14:00:00Z"
//	}
//
// 503 si l'OTA n'est pas configuré (build sans -ldflags).
func (s *Server) handleUpdateCheck(w http.ResponseWriter, r *http.Request) {
	if s.otaClient == nil {
		writeErr(w, http.StatusServiceUnavailable, "OTA non configuré (build local sans version)")
		return
	}
	force := r.URL.Query().Get("force") == "1"
	res, err := s.otaClient.CheckLatest(r.Context(), force)
	if err != nil {
		writeErr(w, http.StatusBadGateway, "échec contact GitHub: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, res)
}

// handleUpdateInstall lance une install async. Retourne 202 Accepted +
// le status initial. L'UI doit ensuite poller /api/update/status.
//
// Body : { "tag": "v0.1.0-alpha.2" } (optionnel, défaut = latest).
//
// 409 si une install est déjà en cours.
// 503 si l'OTA n'est pas configuré.
func (s *Server) handleUpdateInstall(w http.ResponseWriter, r *http.Request) {
	if s.otaInstaller == nil || s.otaClient == nil {
		writeErr(w, http.StatusServiceUnavailable, "OTA non configuré")
		return
	}
	// OpenQIARA Claude V15 (version « -claude ») is not a release of the
	// OpenQiara project: installing a published release from the web UI
	// would replace it and lose its additions (H.265, image settings…).
	// With QIARA Plus installed, /data/openqiarad is its launcher, which an
	// OTA swap would overwrite. Both are refused with an explanation.
	if strings.Contains(s.version, "-claude") || qplus.Default.Installed() {
		writeErr(w, http.StatusConflict, "Mise à jour par l'interface bloquée : cette caméra fait tourner "+
			"OpenQIARA Claude V15 et QIARA Plus, une distribution d'OpenQiara qui n'est pas publiée par le projet. "+
			"Installer une version publiée remplacerait le binaire et le lanceur de QIARA Plus. "+
			"Pour mettre à jour, utiliser l'outil de mise à niveau de la distribution (installation/mettre-a-niveau).")
		return
	}

	var body struct {
		Tag string `json:"tag,omitempty"`
	}
	// Body optionnel — ignore decode error si vide.
	_ = json.NewDecoder(r.Body).Decode(&body)

	tag := body.Tag
	if tag == "" {
		// Default = latest connu (cache si dispo, sinon fetch).
		res, err := s.otaClient.CheckLatest(r.Context(), false)
		if err != nil {
			writeErr(w, http.StatusBadGateway, "échec contact GitHub: "+err.Error())
			return
		}
		tag = res.Latest.TagName
	}
	if tag == "" {
		writeErr(w, http.StatusBadRequest, "aucune release disponible")
		return
	}

	if err := s.otaInstaller.Start(r.Context(), tag); err != nil {
		writeErr(w, http.StatusConflict, err.Error())
		return
	}
	writeJSON(w, http.StatusAccepted, s.otaInstaller.Status())
}

// handleUpdateStatus retourne le snapshot courant de l'install.
// 503 si l'OTA n'est pas configuré.
func (s *Server) handleUpdateStatus(w http.ResponseWriter, _ *http.Request) {
	if s.otaInstaller == nil {
		writeErr(w, http.StatusServiceUnavailable, "OTA non configuré")
		return
	}
	writeJSON(w, http.StatusOK, s.otaInstaller.Status())
}
