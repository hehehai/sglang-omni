package main

import (
	"net/http"

	"github.com/sgl-project/sglang-omni/VoxtNew/internal/helper/proto"
)

// Hooks of the demo build (demo.go, built with -tags demo), which makes
// the README's screenshots and recordings on a Mac: an app of its own
// (another bundle ID, data folder and keys, never the Keychain), seeded
// with sample data and driven from a script. Every hook is nil in other
// builds, which behave exactly as without them.
var (
	demoStart   func()                                            // first in main: the demo's folders and keys
	demoLibrary func(*library)                                    // the library is open: seed it
	demoReady   func(*app)                                        // the window is open: the script's commands
	demoHTTP    *http.Client                                      // the services' HTTP (record and replay)
	demoPerms   func(*proto.PermissionsResult)                    // the helper's permissions, as the demo sees them
	demoMask    func(key string) string                           // a saved key as Model services shows it
	demoNoKeys  bool                                              // no global shortcuts: the user's own VoxtNew keeps fn
	demoDevices func([]proto.CaptureDevice) []proto.CaptureDevice // the microphones listed
	demoFront   func(proto.App) proto.App                         // the app in front, as named
)
