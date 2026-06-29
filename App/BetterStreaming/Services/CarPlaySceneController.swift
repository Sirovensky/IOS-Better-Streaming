import CarPlay
import Foundation
import UIKit

// CarPlay browse + Now Playing.
//
// ⚠️ INERT until the project is configured — this code compiles but is never
// instantiated until ALL of the following are done (none doable from here, all
// Apple/Xcode-gated):
//   1. Add the `com.apple.developer.carplay-audio` entitlement (requires Apple
//      approval for the app's bundle ID).
//   2. Declare a CarPlay scene in Info.plist `UIApplicationSceneManifest`
//      (role `CPTemplateApplicationSceneSessionRoleApplication`) pointing at
//      `CarPlaySceneDelegate`, ALONGSIDE the existing SwiftUI scene — get this
//      exactly right or the main app scene won't launch.
//   3. Test on CarPlay hardware or the CarPlay Simulator.
// Until then this file is dead code (safe — nothing references it).

@MainActor
final class CarPlaySceneDelegate: UIResponder, CPTemplateApplicationSceneDelegate {
    private var interfaceController: CPInterfaceController?

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didConnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = interfaceController
        interfaceController.setRootTemplate(CarPlayBrowser.rootTemplate(), animated: false, completion: nil)
    }

    func templateApplicationScene(
        _ scene: CPTemplateApplicationScene,
        didDisconnect interfaceController: CPInterfaceController
    ) {
        self.interfaceController = nil
    }
}

/// Builds CarPlay browse templates from the shared `AppModel`.
@MainActor
enum CarPlayBrowser {
    static func rootTemplate() -> CPTabBarTemplate {
        CPTabBarTemplate(templates: [recentSection(), playlistsSection(), librarySection()])
    }

    private static func model() -> AppModel? { AppModel.shared }

    private static func recentSection() -> CPListTemplate {
        let tracks = model()?.recentlyPlayed ?? []
        let items = tracks.prefix(50).map { track in
            let item = CPListItem(text: track.title, detailText: track.artist)
            item.handler = { _, completion in
                model()?.play(track, in: tracks)
                completion()
            }
            return item
        }
        let list = CPListTemplate(title: "Recent", sections: [CPListSection(items: Array(items))])
        list.tabImage = UIImage(systemName: "clock")
        return list
    }

    private static func playlistsSection() -> CPListTemplate {
        let playlists = model()?.playlists ?? []
        let items = playlists.map { playlist in
            let item = CPListItem(text: playlist.name, detailText: "\(playlist.trackCount) songs")
            item.handler = { _, completion in
                model()?.playPlaylist(playlist)
                completion()
            }
            return item
        }
        let list = CPListTemplate(title: "Playlists", sections: [CPListSection(items: items)])
        list.tabImage = UIImage(systemName: "music.note.list")
        return list
    }

    private static func librarySection() -> CPListTemplate {
        let shuffle = CPListItem(text: "Shuffle All", detailText: nil)
        shuffle.handler = { _, completion in
            model()?.shuffleAll()
            completion()
        }
        let list = CPListTemplate(title: "Library", sections: [CPListSection(items: [shuffle])])
        list.tabImage = UIImage(systemName: "shuffle")
        return list
    }
}
