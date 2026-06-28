import SwiftUI

@main
struct BetterStreamingApp: App {
    @StateObject private var environment = AppEnvironment()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(environment)
        }
    }
}
