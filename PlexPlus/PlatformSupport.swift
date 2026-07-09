import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Cross-platform semantic colors so the UI code doesn't need `#if` at every
/// call site (macOS uses AppKit system colors, iPadOS uses UIKit ones).
enum Palette {
    static var separator: Color {
        #if os(macOS)
        Color(nsColor: .separatorColor)
        #else
        Color(uiColor: .separator)
        #endif
    }

    static var windowBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemBackground)
        #endif
    }

    static var tertiaryLabel: Color {
        #if os(macOS)
        Color(nsColor: .tertiaryLabelColor)
        #else
        Color(uiColor: .tertiaryLabel)
        #endif
    }

    static var selectedControl: Color {
        #if os(macOS)
        Color(nsColor: .selectedControlColor)
        #else
        Color.accentColor.opacity(0.22)
        #endif
    }
}

/// Opens a URL in the user's default browser (used by the Plex sign-in flow).
enum SystemBrowser {
    static func open(_ url: URL) {
        #if os(macOS)
        NSWorkspace.shared.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
}
