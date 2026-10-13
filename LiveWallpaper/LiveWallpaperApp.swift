import SwiftUI

@main
struct LiveWallpaperApp: App {
    @StateObject private var studio = WallpaperStudio()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            StudioView(studio: studio)
                .preferredColorScheme(.dark)
                .tint(.mint)
                .onChange(of: scenePhase) { _, phase in
                    studio.setActive(phase == .active)
                }
        }
    }
}
