import SwiftUI

@main
struct BluRayCompressorApp: App {
    var body: some Scene {
        WindowGroup("Blu-ray Compressor") {
            ContentView()
                .frame(minWidth: 780, minHeight: 560)
        }
        .windowResizability(.contentSize)
    }
}
