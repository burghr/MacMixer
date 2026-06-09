// MacMixer — "open at login" backed by SMAppService (macOS 13+). The system
// owns the on/off state (visible in System Settings → General → Login Items),
// so there's nothing to persist ourselves.

import ServiceManagement
import Foundation

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    /// Returns false if the system rejected the change (e.g. the app isn't in a
    /// location it can register from).
    @discardableResult
    static func setEnabled(_ enabled: Bool) -> Bool {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
            return true
        } catch {
            NSLog("[MacMixer] login-item toggle failed: %@", error.localizedDescription)
            return false
        }
    }
}
