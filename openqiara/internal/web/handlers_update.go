package web

import (
	"encoding/json"
	"net/http"
	"strings"

	"github.com/caligone/openqiara/internal/config"
	"github.com/caligone/openqiara/internal/qplus"
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
	if res.UpdateNeeded && s.localBuild() {
		// une version locale ne s'installe pas depuis GitHub
		// (handleUpdateInstall refuse) ; la page n'a donc pas à proposer
		// « Installer ». Copie : CheckLatest garde res en cache.
		shown := *res
		shown.UpdateNeeded = false
		res = &shown
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
	// Build local corrigé (suffixe « -claude ») : une installation depuis l'interface remplacerait le
	// binaire par la version publiée, sans le correctif. On la refuse avec une explication.
	// Qiara Plus installed: /data/openqiarad is its launcher, which an OTA swap would overwrite.
	if s.localBuild() {
		writeErr(w, http.StatusConflict, "Mise à jour par l'interface bloquée : cette caméra fait tourner "+
			"OpenQIARA Claude, une distribution d'OpenQiara qui n'est pas publiée par le projet (H.265, réglages d'image, "+
			"santé de la caméra, QIARA Plus). Installer une version publiée remplacerait le binaire et le lanceur de "+
			"QIARA Plus. Pour mettre à jour, utiliser l'outil de mise à niveau de la distribution (mettre-a-niveau).")
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

func (s *Server) handleGetUpdateConfig(w http.ResponseWriter, _ *http.Request) {
	writeJSON(w, http.StatusOK, s.store.Get().Update)
}

// handlePutUpdateConfig active ou coupe l'installation automatique des
// releases. Pris en compte au prochain check, sans redémarrage.
func (s *Server) handlePutUpdateConfig(w http.ResponseWriter, r *http.Request) {
	var body struct {
		Auto *bool `json:"auto"`
	}
	if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
		writeErr(w, http.StatusBadRequest, "JSON invalide")
		return
	}
	if body.Auto == nil {
		writeErr(w, http.StatusBadRequest, "champ 'auto' requis")
		return
	}
	// même garde que l'installation manuelle. Une version locale
	// (« -claude ») ou Qiara Plus installé : l'installation automatique
	// remplacerait le binaire par la release publiée, sans les ajouts locaux.
	if *body.Auto && s.localBuild() {
		writeErr(w, http.StatusConflict, "Installation automatique bloquée : cette caméra fait tourner OpenQIARA Claude, "+
			"une distribution d'OpenQiara qui n'est pas publiée par le projet. Une version publiée remplacerait le binaire "+
			"et le lanceur de QIARA Plus : les mises à jour passent par l'outil de la distribution (mettre-a-niveau).")
		return
	}
	if err := s.store.Update(func(cfg *config.Config) {
		cfg.Update.Auto = *body.Auto
	}); err != nil {
		writeErr(w, http.StatusInternalServerError, "échec sauvegarde: "+err.Error())
		return
	}
	writeJSON(w, http.StatusOK, s.store.Get().Update)
}

// localBuild : version locale (« -claude ») ou Qiara Plus installé.
// Aucune release publiée ne doit alors être installée, ni à la main ni
// automatiquement (voir aussi ota.AutoConfig.Enabled dans main).
func (s *Server) localBuild() bool {
	return strings.Contains(s.version, "-claude") || qplusInstalled()
}

// qplusInstalled dit si Qiara Plus est installé sur cette machine ; variable
// pour que les tests ne dépendent pas de /data/qp (c5 de la relecture).
var qplusInstalled = func() bool { return qplus.Default.Installed() }
