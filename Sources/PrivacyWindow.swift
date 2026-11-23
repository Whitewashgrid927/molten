import AppKit
import SwiftUI

@MainActor final class PrivacyWindow {
    static let shared = PrivacyWindow()
    private var window: NSWindow?

    func show() {
        if let window { window.makeKeyAndOrderFront(nil); return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 430),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Molten Privacy"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: PrivacyContent())
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}

private struct PrivacyContent: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Your creations stay on your Mac").font(.title2.bold())
                Text("Molten works offline. It has no account, advertising, analytics, tracking, or network connection, and the developer does not collect data through the app.")
                Text("Images and audio").font(.headline)
                Text("Molten accesses only files you choose or drop into the app. Images are processed locally for the glass effect, and audio is played locally in the koi turntable. Saving an image writes to the location you select. These files are never uploaded.")
                Text("Preferences and permissions").font(.headline)
                Text("Scene, quality, and frame-rate preferences are stored locally. Molten does not request microphone, camera, screen-recording, or Accessibility access. Animation timing stays on your Mac.")
                Text("Apple services").font(.headline)
                Text("Apple handles App Store and TestFlight downloads and may provide crash reports or beta feedback according to your Apple settings. Apple’s privacy policy governs those services.")
                Text("Updated October 23, 2026").font(.caption).foregroundStyle(.secondary)
            }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
