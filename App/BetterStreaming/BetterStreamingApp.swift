import SwiftUI

@main
struct BetterStreamingApp: App {
    var body: some Scene {
        WindowGroup {
            LaunchRootView()
                .tint(DesignTokens.brandPrimary)
        }
    }
}

private struct LaunchRootView: View {
    @State private var model: AppModel?

    var body: some View {
        Group {
            if let model {
                RootTabView()
                    .environment(model)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "music.note.house.fill")
                        .font(.system(size: 42, weight: .semibold))
                        .foregroundStyle(DesignTokens.brandPrimary)
                    ProgressView()
                        .controlSize(.regular)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .appScreenBackground()
                .task {
                    try? await Task.sleep(nanoseconds: 120_000_000)
                    guard model == nil else { return }
                    model = AppModel()
                }
            }
        }
    }
}
