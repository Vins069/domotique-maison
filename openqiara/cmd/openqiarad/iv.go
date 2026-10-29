package main

import (
	"os"
	"strings"

	"github.com/caligone/openqiara/internal/config"
)

// hlcamdOptionsPath is an optional file of extra hlcamd options, kept for
// cameras whose own post_boot.sh relaunches hlcamd with it.
var hlcamdOptionsPath = "/data/hlcamd_options"

// ivDetectionWanted tells whether the camera's own person and pet detection
// (IntelliVision, in hlcamd) is meant to run: video.iv_detection in the
// configuration (on unless false), and not turned off by an --iv-detection 0
// in the optional options file (the last one counting, as for hlcamd). The
// intent is read rather than the running hlcamd: at each boot hlcamd may
// first run with the vendor's settings, and the entities would come and go.
func ivDetectionWanted(v config.VideoConfig, path string) bool {
	if !v.IVWanted() {
		return false
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return true
	}
	wanted := true
	f := strings.Fields(string(b))
	for i := 0; i+1 < len(f); i++ {
		if f[i] == "--iv-detection" {
			wanted = f[i+1] != "0"
		}
	}
	return wanted
}
