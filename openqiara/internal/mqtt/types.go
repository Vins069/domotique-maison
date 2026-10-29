package mqtt

// discoveryPayload is the HA MQTT auto-discovery config message.
type discoveryPayload struct {
	Name                   string `json:"name"`
	UniqueID               string `json:"unique_id"`
	DeviceClass            string `json:"device_class,omitempty"`
	StateTopic             string `json:"state_topic"`
	CommandTopic           string `json:"command_topic,omitempty"`
	ValueTemplate          string `json:"value_template,omitempty"`
	StateValueTemplate     string `json:"state_value_template,omitempty"` // siren: HA's MQTT siren has no value_template
	SupportDuration        *bool  `json:"support_duration,omitempty"`     // siren: false, the radio siren has no duration...
	SupportVolumeSet       *bool  `json:"support_volume_set,omitempty"`   // ...nor volume (HA would offer settings it ignores)
	PayloadOn              string `json:"payload_on,omitempty"`
	PayloadOff             string `json:"payload_off,omitempty"`
	JSONAttributesTopic    string `json:"json_attributes_topic,omitempty"`
	JSONAttributesTemplate string `json:"json_attributes_template,omitempty"`
	UnitOfMeasurement      string `json:"unit_of_measurement,omitempty"`
	EntityCategory         string `json:"entity_category,omitempty"`
	StateClass             string `json:"state_class,omitempty"`
	// Availability: left out (the entity keeps no availability) for the
	// alarm's sensors, so that a camera dropping off the network cannot
	// turn them "unavailable" under Alarmo; set on the diagnostic entities.
	Availability     []availabilityItem `json:"availability,omitempty"`
	AvailabilityMode string             `json:"availability_mode,omitempty"`
	Icon             string             `json:"icon,omitempty"`
	Options          []string           `json:"options,omitempty"` // enum sensor states, select options
	// number entities: bounds, step and input mode ("box": a typed value).
	Min    *float64 `json:"min,omitempty"`
	Max    *float64 `json:"max,omitempty"`
	Step   *float64 `json:"step,omitempty"`
	Mode   string   `json:"mode,omitempty"`
	Device haDevice `json:"device"`
}

// availabilityItem points an entity at the topic that says whether the
// camera is on the broker (online/offline, with a last will for the
// offline).
type availabilityItem struct {
	Topic               string `json:"topic"`
	PayloadAvailable    string `json:"payload_available,omitempty"`
	PayloadNotAvailable string `json:"payload_not_available,omitempty"`
}

// haDevice is the device block in HA discovery config.
type haDevice struct {
	Identifiers  []string `json:"identifiers"`
	Name         string   `json:"name"`
	Manufacturer string   `json:"manufacturer"`
	Model        string   `json:"model"`
	// Left out when empty, so that the payloads of the existing entities
	// stay as they were.
	SWVersion        string `json:"sw_version,omitempty"`
	ConfigurationURL string `json:"configuration_url,omitempty"`
	ViaDevice        string `json:"via_device,omitempty"`
}

// dwsState is the MQTT state payload for a door/window sensor.
type dwsState struct {
	Open        *bool `json:"open,omitempty"` // absent until the sensor reports after a start
	Battery     int   `json:"battery"`
	Reachable   bool  `json:"reachable"`
	Temperature *int  `json:"temperature,omitempty"` // °C, absent until reported
}

// pirState is the MQTT state payload for a motion sensor.
type pirState struct {
	Motion      *bool `json:"motion,omitempty"` // absent until the sensor reports after a start
	Battery     int   `json:"battery"`
	Reachable   bool  `json:"reachable"`
	Temperature *int  `json:"temperature,omitempty"` // °C, absent until reported
}

// srnState is the MQTT state payload for a siren.
type srnState struct {
	Active      bool   `json:"active"`          // wailing
	State       string `json:"state,omitempty"` // as the siren reports it (camera.Sensor.SirenState)
	Battery     int    `json:"battery"`
	Reachable   bool   `json:"reachable"`
	Temperature *int   `json:"temperature,omitempty"` // °C, absent until reported
}

// kpdState is the MQTT state payload for a keypad event.
type kpdState struct {
	Battery     int  `json:"battery"`
	Reachable   bool `json:"reachable"`
	Temperature *int `json:"temperature,omitempty"` // °C, absent until reported
}
