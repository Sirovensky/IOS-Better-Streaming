import SwiftUI

@main
struct BetterStreamingApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environment(model)
                .tint(DesignTokens.brandPrimary)
        }
    }
}
