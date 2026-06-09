// MacMixer v2 — app entry point. The menu bar status item + popover are owned
// by AppDelegate; the empty Settings scene just satisfies the App protocol
// without showing a window.

import SwiftUI

@main
struct MacMixerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings { EmptyView() }
    }
}
