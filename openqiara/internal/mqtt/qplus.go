package mqtt

import (
	"encoding/json"
	"log/slog"

	mqtt "github.com/eclipse/paho.mqtt.golang"
)

// qplusButton is a Home Assistant button that leaves an order for the
// camera's guard (Qiara Plus). The order list is fixed on both sides.
type qplusButton struct {
	Order       string
	Name        string
	Icon        string
	DeviceClass string
}

var qplusButtons = []qplusButton{
	{Order: "wifi-bounce", Name: "Reconnecter le Wi-Fi", Icon: "mdi:wifi-refresh"},
	{Order: "wifi-driver", Name: "Réinitialiser la puce Wi-Fi", Icon: "mdi:wifi-cog"},
	{Order: "restart-app", Name: "Relancer OpenQiara", Icon: "mdi:restart"},
	{Order: "update-rollback", Name: "Annuler la mise à jour en essai", Icon: "mdi:undo-variant"},
	{Order: "use-prev", Name: "Revenir à la version précédente", Icon: "mdi:history"},
	{Order: "reboot", Name: "Redémarrer la caméra", DeviceClass: "restart"},
	{Order: "ssh-restart", Name: "Relancer SSH", Icon: "mdi:console-network"},
}

func qplusCommandTopic(prefix string) string { return prefix + "/qplus/cmd" }

// buttonPayload is the discovery config of a button (no state topic).
type buttonPayload struct {
	Name           string             `json:"name"`
	UniqueID       string             `json:"unique_id"`
	CommandTopic   string             `json:"command_topic"`
	PayloadPress   string             `json:"payload_press"`
	DeviceClass    string             `json:"device_class,omitempty"`
	EntityCategory string             `json:"entity_category,omitempty"`
	Icon           string             `json:"icon,omitempty"`
	Availability   []availabilityItem `json:"availability,omitempty"`
	Device         haDevice           `json:"device"`
}

func (p *HAPublisher) qplusButtonDiscovery(b qplusButton) (string, []byte) {
	id := "openqiara_qp_" + b.Order
	data, _ := json.Marshal(buttonPayload{
		Name:           b.Name,
		UniqueID:       id,
		CommandTopic:   qplusCommandTopic(p.prefix),
		PayloadPress:   b.Order,
		DeviceClass:    b.DeviceClass,
		EntityCategory: "config",
		Icon:           b.Icon,
		Availability:   p.availability(),
		Device:         cameraDevice(),
	})
	return "homeassistant/button/" + id + "/config", data
}

// SetupQPlusCommandHandler receives the buttons' presses. Only the known
// orders reach the callback; anything else is logged and dropped.
func (p *HAPublisher) SetupQPlusCommandHandler(callback func(order string) error, logger *slog.Logger) {
	p.subscribe(qplusCommandTopic(p.prefix), 1, func(_ mqtt.Client, msg mqtt.Message) {
		order := string(msg.Payload())
		// A retained order is replayed by the broker at every subscription,
		// i.e. at every start: a retained restart-app would restart
		// OpenQiara forever. A press is a moment, never a state.
		if msg.Retained() {
			logger.Warn("qplus: retained order ignored", "payload_len", len(order))
			return
		}
		known := false
		for _, b := range qplusButtons {
			if b.Order == order {
				known = true
			}
		}
		if !known {
			logger.Warn("qplus: unknown order dropped", "payload_len", len(order))
			return
		}
		if err := callback(order); err != nil {
			logger.Warn("qplus: order not left for the guard", "order", order, "error", err)
			return
		}
		logger.Info("qplus: order left for the guard", "order", order)
	})
}
