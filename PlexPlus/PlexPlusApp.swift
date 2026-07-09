import SwiftUI

@main
struct PlexPlusApp: App {
    @StateObject private var model = PlexPlayerViewModel()

    var body: some Scene {
        WindowGroup {
            PlexPlayerContainerView(model: model)
            #if os(macOS)
                .frame(minWidth: 760, minHeight: 480)
            #endif
        }
        #if os(macOS)
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 1200, height: 780)
        .commands {
            // Single-window player; drop the default "New Window" clutter.
            CommandGroup(replacing: .newItem) {}
        }
        #endif
    }
}
