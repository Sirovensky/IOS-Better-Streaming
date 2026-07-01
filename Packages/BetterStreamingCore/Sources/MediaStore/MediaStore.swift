import Foundation
@_exported import BetterStreamingDomain
import GRDB

public typealias PlaybackQueueSnapshot = QueueSnapshot

public struct MediaStoreConfiguration: Sendable {
    public var databaseURL: URL?

    public init(databaseURL: URL? = nil) {
        self.databaseURL = databaseURL
    }

    public static func inMemory() -> MediaStoreConfiguration {
        MediaStoreConfiguration()
    }
}

/// A user-authored metadata correction, keyed by a media item's stable identity
/// key. Stored in its own table and overlaid onto the file-scanned fields when
/// items are read, so a later tag rescan (which rewrites the base row) never
/// clobbers the user's fix. Only non-nil fields override; nil leaves the scanned
/// value showing.
public struct MetadataOverride: Sendable, Equatable {
    public var identityKey: String
    public var title: String?
    public var artist: String?
    public var album: String?
    public var genre: String?
    public var updatedAt: Date

    public init(
        identityKey: String,
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        genre: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.identityKey = identityKey
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.updatedAt = updatedAt
    }

    /// True when the override sets nothing — caller should delete the row instead
    /// of persisting an inert record. Empty/whitespace-only fields count as unset,
    /// so an override that only blanks a title is treated as inert (it would never
    /// overlay anyway; see `applyOverride`).
    public var isEmpty: Bool {
        [title, artist, album, genre].allSatisfy {
            ($0?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) ?? true
        }
    }
}

public enum MediaStoreError: RedactableError, Equatable {
    case invalidStoredValue(table: String, column: String, value: String)

    public var userMessage: String {
        "The media library database contains invalid data."
    }

    public var diagnosticsCode: String {
        switch self {
        case .invalidStoredValue:
            return "media_store.invalid_stored_value"
        }
    }

    public var redactedDebugDescription: String {
        switch self {
        case let .invalidStoredValue(table, column, value):
            return "Invalid value in \(table).\(column): \(value)"
        }
    }
}

public actor MediaStore {
    public let configuration: MediaStoreConfiguration

    private var dbQueue: DatabaseQueue?
    private var didMigrate = false

    public init(configuration: MediaStoreConfiguration = .inMemory()) {
        self.configuration = configuration
    }

    public func migrate() async throws {
        try migrateIfNeededLocked()
    }

    public func migrateIfNeeded() async throws {
        try migrateIfNeededLocked()
    }

    @discardableResult
    public func upsertSource(_ source: SourceRecord) async throws -> SourceRecord {
        try migrateIfNeededLocked()
        try await database().write { db in
            try MediaStorePersistence.upsertSource(source, in: db)
        }
        return source
    }

    public func listSources() async throws -> [SourceRecord] {
        try migrateIfNeededLocked()
        return try await database().read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM sources ORDER BY display_name COLLATE NOCASE, id")
                .map(MediaStorePersistence.source(from:))
        }
    }

    public func source(id: SourceID) async throws -> SourceRecord? {
        try migrateIfNeededLocked()
        return try await database().read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM sources WHERE id = ?",
                arguments: [MediaStorePersistence.uuidString(id.rawValue)]
            ).map(MediaStorePersistence.source(from:))
        }
    }

    public func deleteSource(_ sourceID: SourceID) async throws {
        try migrateIfNeededLocked()
        try await database().write { db in
            try db.execute(
                sql: "DELETE FROM sources WHERE id = ?",
                arguments: [MediaStorePersistence.uuidString(sourceID.rawValue)]
            )
        }
    }

    @discardableResult
    public func upsertFolder(_ folder: FolderItem) async throws -> FolderItem {
        try migrateIfNeededLocked()
        return try await database().write { db in
            try MediaStorePersistence.upsertFolder(folder, in: db)
        }
    }

    @discardableResult
    public func upsertFolders(_ folders: [FolderItem]) async throws -> [FolderItem] {
        try migrateIfNeededLocked()
        return try await database().write { db in
            try folders.map { try MediaStorePersistence.upsertFolder($0, in: db) }
        }
    }

    public func folder(id: FolderID) async throws -> FolderItem? {
        try migrateIfNeededLocked()
        return try await database().read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM folders WHERE id = ?",
                arguments: [MediaStorePersistence.uuidString(id.rawValue)]
            ).map(MediaStorePersistence.folder(from:))
        }
    }

    public func folder(matching identity: RemoteItemIdentity) async throws -> FolderItem? {
        try migrateIfNeededLocked()
        return try await database().read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM folders WHERE identity_key = ?",
                arguments: [identity.stableKey]
            ).map(MediaStorePersistence.folder(from:))
        }
    }

    public func markFolderScanState(_ folderID: FolderID, state: ScanState) async throws {
        try migrateIfNeededLocked()
        try await database().write { db in
            try db.execute(
                sql: """
                UPDATE folders
                SET scan_state = :scan_state, updated_at = :updated_at
                WHERE id = :id
                """,
                arguments: [
                    "id": MediaStorePersistence.uuidString(folderID.rawValue),
                    "scan_state": state.rawValue,
                    "updated_at": Date().timeIntervalSince1970
                ]
            )
        }
    }

    @discardableResult
    public func upsertMediaItem(_ item: MediaItem) async throws -> MediaItem {
        try migrateIfNeededLocked()
        return try await database().write { db in
            try MediaStorePersistence.upsertMediaItem(item, in: db)
        }
    }

    @discardableResult
    public func upsertMediaItems(_ items: [MediaItem]) async throws -> [MediaItem] {
        try migrateIfNeededLocked()
        return try await database().write { db in
            try items.map { try MediaStorePersistence.upsertMediaItem($0, in: db) }
        }
    }

    public func mediaItem(id: MediaItemID) async throws -> MediaItem? {
        try migrateIfNeededLocked()
        return try await database().read { db in
            let overrides = try MediaStorePersistence.overrideIndex(in: db)
            return try Row.fetchOne(
                db,
                sql: "SELECT * FROM media_items WHERE id = ?",
                arguments: [MediaStorePersistence.uuidString(id.rawValue)]
            ).map(MediaStorePersistence.mediaItem(from:))
                .map { MediaStorePersistence.applyOverride($0, overrides.resolve(forStableKey: $0.identity.stableKey)) }
        }
    }

    public func mediaItem(matching identity: RemoteItemIdentity) async throws -> MediaItem? {
        try await mediaItem(identityKey: identity.stableKey)
    }

    /// Fetch a single media item by its stable identity key (== the app's track id),
    /// with any user metadata override already overlaid.
    public func mediaItem(identityKey: String) async throws -> MediaItem? {
        try migrateIfNeededLocked()
        return try await database().read { db in
            let overrides = try MediaStorePersistence.overrideIndex(in: db)
            return try Row.fetchOne(
                db,
                sql: "SELECT * FROM media_items WHERE identity_key = ?",
                arguments: [identityKey]
            ).map(MediaStorePersistence.mediaItem(from:))
                .map { MediaStorePersistence.applyOverride($0, overrides.resolve(forStableKey: $0.identity.stableKey)) }
        }
    }

    /// Update ONLY the duration of a base row, by identity. A full-row upsert
    /// would rewrite the title/artist/album/genre columns from the (possibly
    /// user-edited) in-memory copy, poisoning the file-tag base that metadata
    /// overrides overlay on — so "revert to file tags" would restore the edit.
    /// Column-scoped writes keep the base row = file-scanned values.
    public func setDuration(_ seconds: Double, identityKey: String) async throws {
        try migrateIfNeededLocked()
        try await database().write { db in
            try db.execute(
                sql: "UPDATE media_items SET duration = ? WHERE identity_key = ?",
                arguments: [seconds, identityKey]
            )
        }
    }

    /// Update ONLY the artwork URL of a base row, by identity. Same reason as
    /// `setDuration(_:identityKey:)`: never touch the text columns the overrides
    /// overlay on.
    public func setArtworkURL(_ url: String?, identityKey: String) async throws {
        try migrateIfNeededLocked()
        try await database().write { db in
            try db.execute(
                sql: "UPDATE media_items SET artwork_url = ? WHERE identity_key = ?",
                arguments: [url, identityKey]
            )
        }
    }

    /// Update ONLY the favorite flag of a base row, by identity. Same reason as
    /// `setDuration(_:identityKey:)`.
    public func setFavorite(_ isFavorite: Bool, identityKey: String) async throws {
        try migrateIfNeededLocked()
        try await database().write { db in
            try db.execute(
                sql: "UPDATE media_items SET is_favorite = ? WHERE identity_key = ?",
                arguments: [isFavorite, identityKey]
            )
        }
    }

    public func listMediaItems(sourceID: SourceID? = nil) async throws -> [MediaItem] {
        try migrateIfNeededLocked()
        return try await database().read { db in
            let overrides = try MediaStorePersistence.overrideIndex(in: db)
            let rows: [Row]
            if let sourceID {
                rows = try Row.fetchAll(
                    db,
                    sql: """
                    SELECT * FROM media_items
                    WHERE source_id = ?
                    ORDER BY source_id, share_id, sort_key, file_name
                    """,
                    arguments: [MediaStorePersistence.uuidString(sourceID.rawValue)]
                )
            } else {
                rows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM media_items ORDER BY source_id, share_id, sort_key, file_name"
                )
            }
            return try rows.map(MediaStorePersistence.mediaItem(from:))
                .map { MediaStorePersistence.applyOverride($0, overrides.resolve(forStableKey: $0.identity.stableKey)) }
        }
    }

    @discardableResult
    public func upsertMetadataOverride(_ override: MetadataOverride) async throws -> MetadataOverride {
        try migrateIfNeededLocked()
        try await database().write { db in
            try MediaStorePersistence.upsertMetadataOverride(override, in: db)
        }
        return override
    }

    public func deleteMetadataOverride(identityKey: String) async throws {
        try migrateIfNeededLocked()
        try await database().write { db in
            try MediaStorePersistence.deleteMetadataOverride(identityKey: identityKey, in: db)
        }
    }

    /// Rewrite metadata-override keys after an identity re-key (old → new). Runs in
    /// one transaction; a new key that already carries an override is replaced (the
    /// migrated edit wins). No-op for identical keys or missing sources.
    public func remapMetadataOverrides(_ remap: [String: String]) async throws {
        let pairs = remap.filter { $0.key != $0.value }
        guard !pairs.isEmpty else { return }
        try migrateIfNeededLocked()
        try await database().write { db in
            for (old, new) in pairs {
                guard try Int.fetchOne(db, sql: "SELECT 1 FROM metadata_overrides WHERE identity_key = ?", arguments: [old]) != nil else { continue }
                try db.execute(sql: "DELETE FROM metadata_overrides WHERE identity_key = ?", arguments: [new])
                try db.execute(sql: "UPDATE metadata_overrides SET identity_key = ? WHERE identity_key = ?", arguments: [new, old])
            }
        }
    }

    /// The path-stable prefix (source + share + normalizedPath) of a stable key, or
    /// nil for a malformed key. Public so the app can compute a conservative
    /// identity re-key map from track ids without duplicating the parser.
    public nonisolated static func pathStablePrefix(ofStableKey key: String) -> String? {
        MediaStorePersistence.pathStablePrefix(ofStableKey: key)
    }

    public func metadataOverride(identityKey: String) async throws -> MetadataOverride? {
        try migrateIfNeededLocked()
        return try await database().read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM metadata_overrides WHERE identity_key = ?",
                arguments: [identityKey]
            ).map(MediaStorePersistence.metadataOverride(from:))
        }
    }

    public func listMetadataOverrides() async throws -> [MetadataOverride] {
        try migrateIfNeededLocked()
        return try await database().read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM metadata_overrides")
                .map(MediaStorePersistence.metadataOverride(from:))
        }
    }

    @discardableResult
    public func replaceMediaItems(_ items: [MediaItem], for sourceID: SourceID) async throws -> [MediaItem] {
        try migrateIfNeededLocked()
        return try await database().write { db in
            // Non-destructive: upsert the new set (identity_key match preserves the
            // existing PK, so a surviving track keeps its cache_entries), then
            // delete only the source's items whose identity_key is gone. The old
            // delete-all-then-reinsert reassigned every PK and cascade-wiped valid
            // cache_entries on every rescan.
            let overrides = try MediaStorePersistence.overrideIndex(in: db)
            let persisted = try items.map {
                try MediaStorePersistence.upsertMediaItem(
                    MediaStorePersistence.preservingOverriddenBaseText($0, overrides: overrides, in: db),
                    in: db
                )
            }
            let keep = Set(items.map { $0.identity.stableKey })
            try MediaStorePersistence.deleteMediaItems(sourceID: sourceID, keeping: keep, in: db)
            return persisted
        }
    }

    @discardableResult
    public func replaceAllMediaItems(_ items: [MediaItem]) async throws -> [MediaItem] {
        try migrateIfNeededLocked()
        return try await database().write { db in
            try MediaStorePersistence.deleteAllMediaItems(in: db)
            return try items.map { try MediaStorePersistence.upsertMediaItem($0, in: db) }
        }
    }

    public func deleteMediaItems(sourceID: SourceID) async throws {
        try migrateIfNeededLocked()
        try await database().write { db in
            try MediaStorePersistence.deleteMediaItems(sourceID: sourceID, in: db)
        }
    }

    public func children(of folderID: FolderID) async throws -> FolderChildren {
        try await children(of: Optional(folderID))
    }

    public func children(of folderID: FolderID?) async throws -> FolderChildren {
        try migrateIfNeededLocked()
        return try await database().read { db in
            let overrides = try MediaStorePersistence.overrideIndex(in: db)
            let folderRows: [Row]
            let mediaRows: [Row]
            if let folderID {
                let id = MediaStorePersistence.uuidString(folderID.rawValue)
                folderRows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM folders WHERE parent_folder_id = ? ORDER BY sort_key, name",
                    arguments: [id]
                )
                mediaRows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM media_items WHERE parent_folder_id = ? ORDER BY sort_key, file_name",
                    arguments: [id]
                )
            } else {
                folderRows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM folders WHERE parent_folder_id IS NULL ORDER BY sort_key, name"
                )
                mediaRows = try Row.fetchAll(
                    db,
                    sql: "SELECT * FROM media_items WHERE parent_folder_id IS NULL ORDER BY sort_key, file_name"
                )
            }

            return FolderChildren(
                folders: try folderRows.map(MediaStorePersistence.folder(from:)),
                mediaItems: try mediaRows.map(MediaStorePersistence.mediaItem(from:))
                    .map { MediaStorePersistence.applyOverride($0, overrides.resolve(forStableKey: $0.identity.stableKey)) }
            )
        }
    }

    public func search(_ query: LibrarySearchQuery) async throws -> LibrarySearchResult {
        try migrateIfNeededLocked()
        return try await database().read { db in
            let overrides = try MediaStorePersistence.overrideIndex(in: db)
            let folders = try Row.fetchAll(db, sql: "SELECT * FROM folders ORDER BY sort_key, name")
                .map(MediaStorePersistence.folder(from:))
                .filter { MediaStorePersistence.matches($0, query: query) }
                .prefix(max(query.limit, 0))

            let mediaItems = try Row.fetchAll(db, sql: "SELECT * FROM media_items ORDER BY sort_key, file_name")
                .map(MediaStorePersistence.mediaItem(from:))
                .map { MediaStorePersistence.applyOverride($0, overrides.resolve(forStableKey: $0.identity.stableKey)) }
                .filter { MediaStorePersistence.matches($0, query: query) }
                .prefix(max(query.limit, 0))

            return LibrarySearchResult(folders: Array(folders), mediaItems: Array(mediaItems))
        }
    }

    @discardableResult
    public func upsertPlaylist(_ playlist: Playlist) async throws -> Playlist {
        try migrateIfNeededLocked()
        return try await database().write { db in
            try MediaStorePersistence.upsertPlaylist(playlist, in: db)
        }
    }

    public func playlist(id: PlaylistID) async throws -> Playlist? {
        try migrateIfNeededLocked()
        return try await database().read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM playlists WHERE id = ?",
                arguments: [MediaStorePersistence.uuidString(id.rawValue)]
            ).map(MediaStorePersistence.playlist(from:))
        }
    }

    public func listPlaylists() async throws -> [Playlist] {
        try migrateIfNeededLocked()
        return try await database().read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM playlists ORDER BY name COLLATE NOCASE, id")
                .map(MediaStorePersistence.playlist(from:))
        }
    }

    public func deletePlaylist(_ playlistID: PlaylistID) async throws {
        try migrateIfNeededLocked()
        try await database().write { db in
            try db.execute(
                sql: "DELETE FROM playlists WHERE id = ?",
                arguments: [MediaStorePersistence.uuidString(playlistID.rawValue)]
            )
        }
    }

    public func saveQueueSnapshot(_ snapshot: QueueSnapshot) async throws {
        try migrateIfNeededLocked()
        try await database().write { db in
            try MediaStorePersistence.saveQueueSnapshot(snapshot, in: db)
        }
    }

    public func loadQueueSnapshot() async throws -> QueueSnapshot? {
        try migrateIfNeededLocked()
        return try await database().read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM queue_snapshots WHERE snapshot_key = 'active'")
                .map(MediaStorePersistence.queueSnapshot(from:))
        }
    }

    @discardableResult
    public func upsertCacheEntry(_ entry: CacheEntry) async throws -> CacheEntry {
        try migrateIfNeededLocked()
        return try await database().write { db in
            try MediaStorePersistence.upsertCacheEntry(entry, in: db)
        }
    }

    @discardableResult
    public func upsertCacheRecord(_ record: CacheEntry) async throws -> CacheEntry {
        try await upsertCacheEntry(record)
    }

    public func cacheEntry(for mediaItemID: MediaItemID) async throws -> CacheEntry? {
        try migrateIfNeededLocked()
        return try await database().read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM cache_entries WHERE media_item_id = ?",
                arguments: [MediaStorePersistence.uuidString(mediaItemID.rawValue)]
            ).map(MediaStorePersistence.cacheEntry(from:))
        }
    }

    public func cacheRecord(for mediaItemID: MediaItemID) async throws -> CacheEntry? {
        try await cacheEntry(for: mediaItemID)
    }

    public func saveScanCheckpoint(_ checkpoint: ScanCheckpoint) async throws {
        try migrateIfNeededLocked()
        try await database().write { db in
            try MediaStorePersistence.saveScanCheckpoint(checkpoint, in: db)
        }
    }

    public func scanCheckpoint(for request: ScanRequest) async throws -> ScanCheckpoint? {
        try migrateIfNeededLocked()
        return try await database().read { db in
            try Row.fetchOne(
                db,
                sql: "SELECT * FROM scan_checkpoints WHERE request_key = ?",
                arguments: [request.stableKey]
            ).map(MediaStorePersistence.scanCheckpoint(from:))
        }
    }

    private func migrateIfNeededLocked() throws {
        guard !didMigrate else { return }
        try MediaStorePersistence.migrator().migrate(database())
        didMigrate = true
    }

    private func database() throws -> DatabaseQueue {
        if let dbQueue {
            return dbQueue
        }

        let queue: DatabaseQueue
        if let databaseURL = configuration.databaseURL {
            let parent = databaseURL.deletingLastPathComponent()
            if !parent.path.isEmpty {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            queue = try DatabaseQueue(path: databaseURL.path)
        } else {
            queue = try DatabaseQueue()
        }

        dbQueue = queue
        return queue
    }
}

private enum MediaStorePersistence {
    static func migrator() -> DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("mvp_domain_store") { db in
            for statement in schemaStatements {
                try db.execute(sql: statement)
            }
        }
        migrator.registerMigration("metadata_overrides_v1") { db in
            try db.execute(sql: """
            CREATE TABLE metadata_overrides (
                identity_key TEXT PRIMARY KEY NOT NULL,
                title TEXT,
                artist TEXT,
                album TEXT,
                genre TEXT,
                updated_at REAL NOT NULL
            )
            """)
        }
        return migrator
    }

    static let schemaStatements: [String] = [
        """
        CREATE TABLE sources (
            id TEXT PRIMARY KEY NOT NULL,
            display_name TEXT NOT NULL,
            protocol_kind TEXT NOT NULL,
            endpoint_json TEXT NOT NULL,
            credential_ref_json TEXT,
            roots_json TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE folders (
            id TEXT PRIMARY KEY NOT NULL,
            identity_key TEXT NOT NULL UNIQUE,
            identity_json TEXT NOT NULL,
            source_id TEXT NOT NULL,
            share_id TEXT NOT NULL,
            display_path TEXT NOT NULL,
            normalized_path TEXT NOT NULL,
            remote_file_id TEXT,
            size INTEGER,
            modified_at REAL,
            parent_folder_id TEXT,
            name TEXT NOT NULL,
            scan_state TEXT NOT NULL,
            sort_key TEXT NOT NULL,
            failure_code TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        )
        """,
        "CREATE INDEX idx_folders_parent ON folders(parent_folder_id, sort_key)",
        "CREATE INDEX idx_folders_source_share_path ON folders(source_id, share_id, normalized_path)",
        """
        CREATE TABLE media_items (
            id TEXT PRIMARY KEY NOT NULL,
            identity_key TEXT NOT NULL UNIQUE,
            identity_json TEXT NOT NULL,
            source_id TEXT NOT NULL,
            share_id TEXT NOT NULL,
            display_path TEXT NOT NULL,
            normalized_path TEXT NOT NULL,
            remote_file_id TEXT,
            size INTEGER,
            modified_at REAL,
            parent_folder_id TEXT,
            media_kind TEXT NOT NULL,
            file_name TEXT NOT NULL,
            title TEXT,
            artist TEXT,
            album TEXT,
            genre TEXT,
            track_number INTEGER,
            disc_number INTEGER,
            duration REAL,
            artwork_url TEXT,
            is_favorite INTEGER NOT NULL DEFAULT 0,
            sort_key TEXT NOT NULL,
            playback_capability_json TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        )
        """,
        "CREATE INDEX idx_media_items_parent ON media_items(parent_folder_id, sort_key)",
        "CREATE INDEX idx_media_items_source_share_path ON media_items(source_id, share_id, normalized_path)",
        "CREATE INDEX idx_media_items_kind ON media_items(media_kind)",
        """
        CREATE VIRTUAL TABLE media_search USING fts5(
            media_id UNINDEXED,
            file_name,
            title,
            artist,
            album,
            genre,
            display_path,
            tokenize='unicode61 remove_diacritics 2'
        )
        """,
        """
        CREATE TABLE playlists (
            id TEXT PRIMARY KEY NOT NULL,
            name TEXT NOT NULL,
            kind TEXT NOT NULL,
            entries_json TEXT NOT NULL,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE playlist_entries (
            id TEXT PRIMARY KEY NOT NULL,
            playlist_id TEXT NOT NULL,
            position INTEGER NOT NULL,
            target_type TEXT NOT NULL,
            target_id TEXT NOT NULL,
            recursive INTEGER NOT NULL DEFAULT 0,
            title TEXT,
            FOREIGN KEY(playlist_id) REFERENCES playlists(id) ON DELETE CASCADE
        )
        """,
        "CREATE INDEX idx_playlist_entries_playlist ON playlist_entries(playlist_id, position)",
        """
        CREATE TABLE queue_snapshots (
            snapshot_key TEXT PRIMARY KEY NOT NULL,
            queue_id TEXT NOT NULL,
            items_json TEXT NOT NULL,
            current_index INTEGER,
            is_shuffled INTEGER NOT NULL,
            repeat_mode TEXT NOT NULL,
            updated_at REAL NOT NULL
        )
        """,
        """
        CREATE TABLE cache_entries (
            id TEXT PRIMARY KEY NOT NULL,
            media_item_id TEXT NOT NULL UNIQUE,
            identity_key TEXT NOT NULL,
            identity_json TEXT NOT NULL,
            state TEXT NOT NULL,
            local_file_url TEXT,
            bytes_total INTEGER,
            bytes_done INTEGER NOT NULL,
            required_by_json TEXT NOT NULL,
            last_played_at REAL,
            last_verified_at REAL,
            failure_code TEXT,
            created_at REAL NOT NULL,
            updated_at REAL NOT NULL
        )
        """,
        "CREATE INDEX idx_cache_entries_state ON cache_entries(state)",
        "CREATE INDEX idx_cache_entries_identity ON cache_entries(identity_key)",
        """
        CREATE TABLE scan_checkpoints (
            request_key TEXT PRIMARY KEY NOT NULL,
            scan_id TEXT NOT NULL,
            request_json TEXT NOT NULL,
            progress_json TEXT NOT NULL,
            updated_at REAL NOT NULL,
            completed_at REAL,
            failure_code TEXT
        )
        """
    ]

    static func upsertSource(_ source: SourceRecord, in db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO sources (
                id, display_name, protocol_kind, endpoint_json, credential_ref_json,
                roots_json, created_at, updated_at
            )
            VALUES (
                :id, :display_name, :protocol_kind, :endpoint_json, :credential_ref_json,
                :roots_json, :created_at, :updated_at
            )
            ON CONFLICT(id) DO UPDATE SET
                display_name = excluded.display_name,
                protocol_kind = excluded.protocol_kind,
                endpoint_json = excluded.endpoint_json,
                credential_ref_json = excluded.credential_ref_json,
                roots_json = excluded.roots_json,
                updated_at = excluded.updated_at
            """,
            arguments: [
                "id": uuidString(source.id.rawValue),
                "display_name": source.displayName,
                "protocol_kind": source.protocolKind.rawValue,
                "endpoint_json": try encode(source.endpoint),
                "credential_ref_json": try optionalEncode(source.credentialRef),
                "roots_json": try encode(source.roots),
                "created_at": source.createdAt.timeIntervalSince1970,
                "updated_at": source.updatedAt.timeIntervalSince1970
            ]
        )
    }

    static func source(from row: Row) throws -> SourceRecord {
        let id = try sourceID(row["id"], table: "sources", column: "id")
        let protocolRaw: String = row["protocol_kind"]
        guard let protocolKind = SourceProtocolKind(rawValue: protocolRaw) else {
            throw MediaStoreError.invalidStoredValue(table: "sources", column: "protocol_kind", value: protocolRaw)
        }
        let credentialJSON: String? = row["credential_ref_json"]
        let createdAtSeconds: Double = row["created_at"]
        let updatedAtSeconds: Double = row["updated_at"]

        return SourceRecord(
            id: id,
            displayName: row["display_name"],
            protocolKind: protocolKind,
            endpoint: try decode(SourceEndpoint.self, from: row["endpoint_json"]),
            credentialRef: try credentialJSON.map { try decode(CredentialRef.self, from: $0) },
            roots: try decode([SourceRoot].self, from: row["roots_json"]),
            createdAt: Date(timeIntervalSince1970: createdAtSeconds),
            updatedAt: Date(timeIntervalSince1970: updatedAtSeconds)
        )
    }

    static func upsertFolder(_ folder: FolderItem, in db: Database) throws -> FolderItem {
        let identityKey = folder.identity.stableKey
        let existingID = try String.fetchOne(
            db,
            sql: "SELECT id FROM folders WHERE identity_key = ?",
            arguments: [identityKey]
        )
        let passedID = uuidString(folder.id.rawValue)
        let rowID = existingID ?? passedID
        let persisted = FolderItem(
            id: try folderID(rowID, table: "folders", column: "id"),
            identity: folder.identity,
            parentFolderID: folder.parentFolderID,
            name: folder.name,
            scanState: folder.scanState,
            sortKey: folder.sortKey,
            failureCode: folder.failureCode
        )
        let now = Date().timeIntervalSince1970

        let shouldUpdate = existingID != nil ? true : try folderExists(id: passedID, in: db)
        if shouldUpdate {
            try db.execute(
                sql: """
                UPDATE folders SET
                    identity_key = :identity_key,
                    identity_json = :identity_json,
                    source_id = :source_id,
                    share_id = :share_id,
                    display_path = :display_path,
                    normalized_path = :normalized_path,
                    remote_file_id = :remote_file_id,
                    size = :size,
                    modified_at = :modified_at,
                    parent_folder_id = :parent_folder_id,
                    name = :name,
                    scan_state = :scan_state,
                    sort_key = :sort_key,
                    failure_code = :failure_code,
                    updated_at = :updated_at
                WHERE id = :id
                """,
                arguments: folderArguments(persisted, now: now, includeCreatedAt: false)
            )
        } else {
            try db.execute(
                sql: """
                INSERT INTO folders (
                    id, identity_key, identity_json, source_id, share_id, display_path,
                    normalized_path, remote_file_id, size, modified_at, parent_folder_id,
                    name, scan_state, sort_key, failure_code, created_at, updated_at
                )
                VALUES (
                    :id, :identity_key, :identity_json, :source_id, :share_id, :display_path,
                    :normalized_path, :remote_file_id, :size, :modified_at, :parent_folder_id,
                    :name, :scan_state, :sort_key, :failure_code, :created_at, :updated_at
                )
                """,
                arguments: folderArguments(persisted, now: now, includeCreatedAt: true)
            )
        }

        return persisted
    }

    static func folder(from row: Row) throws -> FolderItem {
        let scanStateRaw: String = row["scan_state"]
        guard let scanState = ScanState(rawValue: scanStateRaw) else {
            throw MediaStoreError.invalidStoredValue(table: "folders", column: "scan_state", value: scanStateRaw)
        }
        let parentID: String? = row["parent_folder_id"]
        let failureCode: String? = row["failure_code"]

        return FolderItem(
            id: try folderID(row["id"], table: "folders", column: "id"),
            identity: try decode(RemoteItemIdentity.self, from: row["identity_json"]),
            parentFolderID: try parentID.map { try folderID($0, table: "folders", column: "parent_folder_id") },
            name: row["name"],
            scanState: scanState,
            sortKey: row["sort_key"],
            failureCode: failureCode
        )
    }

    static func upsertMediaItem(_ item: MediaItem, in db: Database) throws -> MediaItem {
        let identityKey = item.identity.stableKey
        let existingID = try String.fetchOne(
            db,
            sql: "SELECT id FROM media_items WHERE identity_key = ?",
            arguments: [identityKey]
        )
        let passedID = uuidString(item.id.rawValue)
        let rowID = existingID ?? passedID
        let persisted = MediaItem(
            id: try mediaItemID(rowID, table: "media_items", column: "id"),
            identity: item.identity,
            parentFolderID: item.parentFolderID,
            mediaKind: item.mediaKind,
            fileName: item.fileName,
            title: item.title,
            artist: item.artist,
            album: item.album,
            genre: item.genre,
            trackNumber: item.trackNumber,
            discNumber: item.discNumber,
            duration: item.duration,
            artworkURL: item.artworkURL,
            isFavorite: item.isFavorite,
            sortKey: item.sortKey,
            playbackCapability: item.playbackCapability
        )
        let now = Date().timeIntervalSince1970

        let shouldUpdate = existingID != nil ? true : try mediaItemExists(id: passedID, in: db)
        if shouldUpdate {
            try db.execute(
                sql: """
                UPDATE media_items SET
                    identity_key = :identity_key,
                    identity_json = :identity_json,
                    source_id = :source_id,
                    share_id = :share_id,
                    display_path = :display_path,
                    normalized_path = :normalized_path,
                    remote_file_id = :remote_file_id,
                    size = :size,
                    modified_at = :modified_at,
                    parent_folder_id = :parent_folder_id,
                    media_kind = :media_kind,
                    file_name = :file_name,
                    title = :title,
                    artist = :artist,
                    album = :album,
                    genre = :genre,
                    track_number = :track_number,
                    disc_number = :disc_number,
                    duration = :duration,
                    artwork_url = :artwork_url,
                    is_favorite = :is_favorite,
                    sort_key = :sort_key,
                    playback_capability_json = :playback_capability_json,
                    updated_at = :updated_at
                WHERE id = :id
                """,
                arguments: mediaItemArguments(persisted, now: now, includeCreatedAt: false)
            )
        } else {
            try db.execute(
                sql: """
                INSERT INTO media_items (
                    id, identity_key, identity_json, source_id, share_id, display_path,
                    normalized_path, remote_file_id, size, modified_at, parent_folder_id,
                    media_kind, file_name, title, artist, album, genre, track_number,
                    disc_number, duration, artwork_url, is_favorite, sort_key, playback_capability_json,
                    created_at, updated_at
                )
                VALUES (
                    :id, :identity_key, :identity_json, :source_id, :share_id, :display_path,
                    :normalized_path, :remote_file_id, :size, :modified_at, :parent_folder_id,
                    :media_kind, :file_name, :title, :artist, :album, :genre, :track_number,
                    :disc_number, :duration, :artwork_url, :is_favorite, :sort_key, :playback_capability_json,
                    :created_at, :updated_at
                )
                """,
                arguments: mediaItemArguments(persisted, now: now, includeCreatedAt: true)
            )
        }

        try db.execute(sql: "DELETE FROM media_search WHERE media_id = ?", arguments: [uuidString(persisted.id.rawValue)])
        try db.execute(
            sql: """
            INSERT INTO media_search (media_id, file_name, title, artist, album, genre, display_path)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            arguments: [
                uuidString(persisted.id.rawValue),
                persisted.fileName,
                persisted.title,
                persisted.artist,
                persisted.album,
                persisted.genre,
                persisted.identity.path.displayPath
            ]
        )

        return persisted
    }

    static func mediaItem(from row: Row) throws -> MediaItem {
        let mediaKindRaw: String = row["media_kind"]
        guard let mediaKind = MediaKind(rawValue: mediaKindRaw) else {
            throw MediaStoreError.invalidStoredValue(table: "media_items", column: "media_kind", value: mediaKindRaw)
        }
        let parentID: String? = row["parent_folder_id"]
        let playbackJSON: String? = row["playback_capability_json"]
        let artworkURLString: String? = row["artwork_url"]
        let isFavorite: Int = row["is_favorite"]

        return MediaItem(
            id: try mediaItemID(row["id"], table: "media_items", column: "id"),
            identity: try decode(RemoteItemIdentity.self, from: row["identity_json"]),
            parentFolderID: try parentID.map { try folderID($0, table: "media_items", column: "parent_folder_id") },
            mediaKind: mediaKind,
            fileName: row["file_name"],
            title: row["title"],
            artist: row["artist"],
            album: row["album"],
            genre: row["genre"],
            trackNumber: row["track_number"],
            discNumber: row["disc_number"],
            duration: row["duration"],
            artworkURL: artworkURLString.flatMap(URL.init(string:)),
            isFavorite: isFavorite != 0,
            sortKey: row["sort_key"],
            playbackCapability: try playbackJSON.map { try decode(PlaybackCapability.self, from: $0) }
        )
    }

    // MARK: Metadata overrides

    /// Lookup over the stored overrides that survives identity drift. Overrides are
    /// keyed on a media item's full `stableKey` (which embeds size + mtime), but a
    /// server re-tag or a NAS clock/mtime drift across reconnects mints a NEW full
    /// stableKey for the SAME file — which would silently stop the override from
    /// overlaying. So we also index every override by its PATH-STABLE prefix
    /// (source + share + normalizedPath, no size/mtime) and fall back to that when
    /// the exact key misses. This keeps the "edits survive a rescan" guarantee
    /// without a schema migration.
    struct OverrideIndex {
        var byIdentityKey: [String: MetadataOverride]
        var byPathPrefix: [String: MetadataOverride]

        func resolve(forStableKey key: String) -> MetadataOverride? {
            if let exact = byIdentityKey[key] { return exact }
            guard let prefix = MediaStorePersistence.pathStablePrefix(ofStableKey: key) else { return nil }
            return byPathPrefix[prefix]
        }
    }

    /// Load every override, indexed both by exact identity_key and by path-stable
    /// prefix. Overrides are sparse (only user-edited items), so this stays small
    /// even for a large library. When two overrides collapse to the same path
    /// prefix (an old + a re-tagged key for one file), the most recently edited wins.
    static func overrideIndex(in db: Database) throws -> OverrideIndex {
        var byKey: [String: MetadataOverride] = [:]
        var byPrefix: [String: MetadataOverride] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT * FROM metadata_overrides") {
            let override = try metadataOverride(from: row)
            byKey[override.identityKey] = override
            if let prefix = pathStablePrefix(ofStableKey: override.identityKey) {
                if let existing = byPrefix[prefix], existing.updatedAt >= override.updatedAt { continue }
                byPrefix[prefix] = override
            }
        }
        return OverrideIndex(byIdentityKey: byKey, byPathPrefix: byPrefix)
    }

    /// The path-stable prefix of a `RemoteItemIdentity.stableKey`: source + share +
    /// normalizedPath, dropping the volatile remoteFileID/size/mtime tail. A
    /// stableKey is the concatenation of length-prefixed fields ("<utf8len>:<value>")
    /// in a fixed order, so the path-stable key is literally the prefix spanning the
    /// first three fields. Returns nil for a malformed key.
    static func pathStablePrefix(ofStableKey key: String) -> String? {
        let bytes = Array(key.utf8)
        let zero = UInt8(ascii: "0"), nine = UInt8(ascii: "9"), colon = UInt8(ascii: ":")
        var index = 0
        for _ in 0..<3 {
            var length = 0
            var sawDigit = false
            while index < bytes.count, bytes[index] >= zero, bytes[index] <= nine {
                length = length * 10 + Int(bytes[index] - zero)
                index += 1
                sawDigit = true
            }
            guard sawDigit, index < bytes.count, bytes[index] == colon else { return nil }
            index += 1 + length
            guard index <= bytes.count else { return nil }
        }
        return String(decoding: bytes[0..<index], as: UTF8.self)
    }

    /// Overlay an override's set fields onto a scanned item. Empty/whitespace-only
    /// fields are treated as unset so an inert override can't blank a real title.
    static func applyOverride(_ item: MediaItem, _ override: MetadataOverride?) -> MediaItem {
        guard let override else { return item }
        var copy = item
        if let title = nonBlank(override.title) { copy.title = title }
        if let artist = nonBlank(override.artist) { copy.artist = artist }
        if let album = nonBlank(override.album) { copy.album = album }
        if let genre = nonBlank(override.genre) { copy.genre = genre }
        return copy
    }

    /// nil for nil or empty/whitespace-only strings, otherwise the original value.
    static func nonBlank(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    /// Delete a track's override. Removes the exact key AND any override whose
    /// path-stable prefix matches — after identity drift the live override is stored
    /// under an OLD key that still prefix-resolves for the new key (see
    /// `OverrideIndex`), so a "revert to file tags" via the new key must clear it too
    /// or it resurrects next launch.
    static func deleteMetadataOverride(identityKey: String, in db: Database) throws {
        try db.execute(sql: "DELETE FROM metadata_overrides WHERE identity_key = ?", arguments: [identityKey])
        guard let prefix = pathStablePrefix(ofStableKey: identityKey) else { return }
        let keys = try String.fetchAll(db, sql: "SELECT identity_key FROM metadata_overrides")
        for key in keys where pathStablePrefix(ofStableKey: key) == prefix {
            try db.execute(sql: "DELETE FROM metadata_overrides WHERE identity_key = ?", arguments: [key])
        }
    }

    /// When an incoming item's identity carries a metadata override AND a base row
    /// already exists, keep that base row's file-tag text columns instead of the
    /// item's. A reused in-memory track carries overlay-APPLIED text, and stamping
    /// that into the base row would make "revert to file tags" restore the edit.
    /// A brand-new (re-keyed) file has no existing row, so its file-scanned text
    /// passes through unchanged.
    static func preservingOverriddenBaseText(_ item: MediaItem, overrides: OverrideIndex, in db: Database) throws -> MediaItem {
        guard overrides.resolve(forStableKey: item.identity.stableKey) != nil else { return item }
        guard let row = try Row.fetchOne(
            db,
            sql: "SELECT title, artist, album, genre FROM media_items WHERE identity_key = ?",
            arguments: [item.identity.stableKey]
        ) else { return item }
        var copy = item
        copy.title = row["title"]
        copy.artist = row["artist"]
        copy.album = row["album"]
        copy.genre = row["genre"]
        return copy
    }

    static func upsertMetadataOverride(_ override: MetadataOverride, in db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO metadata_overrides (identity_key, title, artist, album, genre, updated_at)
            VALUES (:identity_key, :title, :artist, :album, :genre, :updated_at)
            ON CONFLICT(identity_key) DO UPDATE SET
                title = excluded.title,
                artist = excluded.artist,
                album = excluded.album,
                genre = excluded.genre,
                updated_at = excluded.updated_at
            """,
            arguments: [
                "identity_key": override.identityKey,
                "title": nonBlank(override.title),
                "artist": nonBlank(override.artist),
                "album": nonBlank(override.album),
                "genre": nonBlank(override.genre),
                "updated_at": override.updatedAt.timeIntervalSince1970
            ]
        )
    }

    /// Drop overrides whose underlying file is gone. Matches on the path-stable
    /// prefix, NOT the exact identity_key, so a rescan that changed a file's
    /// size/mtime (new full stableKey) doesn't orphan a still-valid override that
    /// the path-stable fallback would still overlay. A malformed key (no parseable
    /// prefix) has no live file and is pruned. Runs inside the caller's transaction.
    static func pruneOrphanedOverrides(in db: Database) throws {
        let livePrefixes = Set(
            try String.fetchAll(db, sql: "SELECT identity_key FROM media_items")
                .compactMap(pathStablePrefix(ofStableKey:))
        )
        let overrideKeys = try String.fetchAll(db, sql: "SELECT identity_key FROM metadata_overrides")
        for key in overrideKeys where !(pathStablePrefix(ofStableKey: key).map(livePrefixes.contains) ?? false) {
            try db.execute(sql: "DELETE FROM metadata_overrides WHERE identity_key = ?", arguments: [key])
        }
    }

    static func metadataOverride(from row: Row) throws -> MetadataOverride {
        let updatedAtSeconds: Double = row["updated_at"]
        return MetadataOverride(
            identityKey: row["identity_key"],
            title: row["title"],
            artist: row["artist"],
            album: row["album"],
            genre: row["genre"],
            updatedAt: Date(timeIntervalSince1970: updatedAtSeconds)
        )
    }

    static func upsertPlaylist(_ playlist: Playlist, in db: Database) throws -> Playlist {
        try db.execute(
            sql: """
            INSERT INTO playlists (id, name, kind, entries_json, created_at, updated_at)
            VALUES (:id, :name, :kind, :entries_json, :created_at, :updated_at)
            ON CONFLICT(id) DO UPDATE SET
                name = excluded.name,
                kind = excluded.kind,
                entries_json = excluded.entries_json,
                updated_at = excluded.updated_at
            """,
            arguments: [
                "id": uuidString(playlist.id.rawValue),
                "name": playlist.name,
                "kind": playlist.kind.rawValue,
                "entries_json": try encode(playlist.entries),
                "created_at": playlist.createdAt.timeIntervalSince1970,
                "updated_at": playlist.updatedAt.timeIntervalSince1970
            ]
        )

        try db.execute(
            sql: "DELETE FROM playlist_entries WHERE playlist_id = ?",
            arguments: [uuidString(playlist.id.rawValue)]
        )
        for entry in playlist.entries.sorted(by: { $0.position < $1.position }) {
            let target = playlistEntryTarget(entry.target)
            try db.execute(
                sql: """
                INSERT INTO playlist_entries (
                    id, playlist_id, position, target_type, target_id, recursive, title
                )
                VALUES (:id, :playlist_id, :position, :target_type, :target_id, :recursive, :title)
                """,
                arguments: [
                    "id": uuidString(entry.id),
                    "playlist_id": uuidString(playlist.id.rawValue),
                    "position": entry.position,
                    "target_type": target.type,
                    "target_id": target.id,
                    "recursive": target.recursive ? 1 : 0,
                    "title": entry.title
                ]
            )
        }

        return playlist
    }

    static func playlist(from row: Row) throws -> Playlist {
        let kindRaw: String = row["kind"]
        guard let kind = PlaylistKind(rawValue: kindRaw) else {
            throw MediaStoreError.invalidStoredValue(table: "playlists", column: "kind", value: kindRaw)
        }
        let createdAtSeconds: Double = row["created_at"]
        let updatedAtSeconds: Double = row["updated_at"]

        return Playlist(
            id: try playlistID(row["id"], table: "playlists", column: "id"),
            name: row["name"],
            kind: kind,
            entries: try decode([PlaylistEntry].self, from: row["entries_json"]),
            createdAt: Date(timeIntervalSince1970: createdAtSeconds),
            updatedAt: Date(timeIntervalSince1970: updatedAtSeconds)
        )
    }

    static func saveQueueSnapshot(_ snapshot: QueueSnapshot, in db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO queue_snapshots (
                snapshot_key, queue_id, items_json, current_index, is_shuffled, repeat_mode, updated_at
            )
            VALUES (
                'active', :queue_id, :items_json, :current_index, :is_shuffled, :repeat_mode, :updated_at
            )
            ON CONFLICT(snapshot_key) DO UPDATE SET
                queue_id = excluded.queue_id,
                items_json = excluded.items_json,
                current_index = excluded.current_index,
                is_shuffled = excluded.is_shuffled,
                repeat_mode = excluded.repeat_mode,
                updated_at = excluded.updated_at
            """,
            arguments: [
                "queue_id": uuidString(snapshot.id.rawValue),
                "items_json": try encode(snapshot.items),
                "current_index": snapshot.currentIndex,
                "is_shuffled": snapshot.isShuffled ? 1 : 0,
                "repeat_mode": snapshot.repeatMode.rawValue,
                "updated_at": snapshot.updatedAt.timeIntervalSince1970
            ]
        )
    }

    static func queueSnapshot(from row: Row) throws -> QueueSnapshot {
        let repeatRaw: String = row["repeat_mode"]
        guard let repeatMode = QueueRepeatMode(rawValue: repeatRaw) else {
            throw MediaStoreError.invalidStoredValue(table: "queue_snapshots", column: "repeat_mode", value: repeatRaw)
        }
        let updatedAtSeconds: Double = row["updated_at"]
        let isShuffled: Int = row["is_shuffled"]

        return QueueSnapshot(
            id: try queueID(row["queue_id"], table: "queue_snapshots", column: "queue_id"),
            items: try decode([QueueEntry].self, from: row["items_json"]),
            currentIndex: row["current_index"],
            isShuffled: isShuffled != 0,
            repeatMode: repeatMode,
            updatedAt: Date(timeIntervalSince1970: updatedAtSeconds)
        )
    }

    static func upsertCacheEntry(_ entry: CacheEntry, in db: Database) throws -> CacheEntry {
        let existingID = try String.fetchOne(
            db,
            sql: "SELECT id FROM cache_entries WHERE media_item_id = ?",
            arguments: [uuidString(entry.mediaItemID.rawValue)]
        )
        let persisted = CacheEntry(
            id: try existingID.map { try uuid($0, table: "cache_entries", column: "id") } ?? entry.id,
            mediaItemID: entry.mediaItemID,
            identity: entry.identity,
            state: entry.state,
            localFileURL: entry.localFileURL,
            bytesTotal: entry.bytesTotal,
            bytesDone: entry.bytesDone,
            requiredBy: entry.requiredBy,
            lastPlayedAt: entry.lastPlayedAt,
            lastVerifiedAt: entry.lastVerifiedAt,
            failureCode: entry.failureCode
        )
        let now = Date().timeIntervalSince1970

        try db.execute(
            sql: """
            INSERT INTO cache_entries (
                id, media_item_id, identity_key, identity_json, state, local_file_url,
                bytes_total, bytes_done, required_by_json, last_played_at, last_verified_at,
                failure_code, created_at, updated_at
            )
            VALUES (
                :id, :media_item_id, :identity_key, :identity_json, :state, :local_file_url,
                :bytes_total, :bytes_done, :required_by_json, :last_played_at, :last_verified_at,
                :failure_code, :created_at, :updated_at
            )
            ON CONFLICT(media_item_id) DO UPDATE SET
                identity_key = excluded.identity_key,
                identity_json = excluded.identity_json,
                state = excluded.state,
                local_file_url = excluded.local_file_url,
                bytes_total = excluded.bytes_total,
                bytes_done = excluded.bytes_done,
                required_by_json = excluded.required_by_json,
                last_played_at = excluded.last_played_at,
                last_verified_at = excluded.last_verified_at,
                failure_code = excluded.failure_code,
                updated_at = excluded.updated_at
            """,
            arguments: [
                "id": uuidString(persisted.id),
                "media_item_id": uuidString(persisted.mediaItemID.rawValue),
                "identity_key": persisted.identity.stableKey,
                "identity_json": try encode(persisted.identity),
                "state": persisted.state.rawValue,
                "local_file_url": persisted.localFileURL?.absoluteString,
                "bytes_total": persisted.bytesTotal,
                "bytes_done": persisted.bytesDone,
                "required_by_json": try encode(persisted.requiredBy),
                "last_played_at": persisted.lastPlayedAt?.timeIntervalSince1970,
                "last_verified_at": persisted.lastVerifiedAt?.timeIntervalSince1970,
                "failure_code": persisted.failureCode,
                "created_at": now,
                "updated_at": now
            ]
        )

        return persisted
    }

    static func cacheEntry(from row: Row) throws -> CacheEntry {
        let stateRaw: String = row["state"]
        guard let state = CacheState(rawValue: stateRaw) else {
            throw MediaStoreError.invalidStoredValue(table: "cache_entries", column: "state", value: stateRaw)
        }
        let localURLString: String? = row["local_file_url"]
        let lastPlayedAt: Double? = row["last_played_at"]
        let lastVerifiedAt: Double? = row["last_verified_at"]

        return CacheEntry(
            id: try uuid(row["id"], table: "cache_entries", column: "id"),
            mediaItemID: try mediaItemID(row["media_item_id"], table: "cache_entries", column: "media_item_id"),
            identity: try decode(RemoteItemIdentity.self, from: row["identity_json"]),
            state: state,
            localFileURL: localURLString.flatMap(URL.init(string:)),
            bytesTotal: row["bytes_total"],
            bytesDone: row["bytes_done"],
            requiredBy: try decode(Set<CacheRequiredBy>.self, from: row["required_by_json"]),
            lastPlayedAt: lastPlayedAt.map(Date.init(timeIntervalSince1970:)),
            lastVerifiedAt: lastVerifiedAt.map(Date.init(timeIntervalSince1970:)),
            failureCode: row["failure_code"]
        )
    }

    static func saveScanCheckpoint(_ checkpoint: ScanCheckpoint, in db: Database) throws {
        try db.execute(
            sql: """
            INSERT INTO scan_checkpoints (
                request_key, scan_id, request_json, progress_json, updated_at, completed_at, failure_code
            )
            VALUES (
                :request_key, :scan_id, :request_json, :progress_json, :updated_at, :completed_at, :failure_code
            )
            ON CONFLICT(request_key) DO UPDATE SET
                scan_id = excluded.scan_id,
                request_json = excluded.request_json,
                progress_json = excluded.progress_json,
                updated_at = excluded.updated_at,
                completed_at = excluded.completed_at,
                failure_code = excluded.failure_code
            """,
            arguments: [
                "request_key": checkpoint.request.stableKey,
                "scan_id": uuidString(checkpoint.id.rawValue),
                "request_json": try encode(checkpoint.request),
                "progress_json": try encode(checkpoint.progress),
                "updated_at": checkpoint.updatedAt.timeIntervalSince1970,
                "completed_at": checkpoint.completedAt?.timeIntervalSince1970,
                "failure_code": checkpoint.failureCode
            ]
        )
    }

    static func scanCheckpoint(from row: Row) throws -> ScanCheckpoint {
        let updatedAtSeconds: Double = row["updated_at"]
        let completedAtSeconds: Double? = row["completed_at"]

        return ScanCheckpoint(
            id: try scanID(row["scan_id"], table: "scan_checkpoints", column: "scan_id"),
            request: try decode(ScanRequest.self, from: row["request_json"]),
            progress: try decode(ScanProgress.self, from: row["progress_json"]),
            updatedAt: Date(timeIntervalSince1970: updatedAtSeconds),
            completedAt: completedAtSeconds.map(Date.init(timeIntervalSince1970:)),
            failureCode: row["failure_code"]
        )
    }

    static func matches(_ folder: FolderItem, query: LibrarySearchQuery) -> Bool {
        guard matchesIdentity(folder.identity, query: query) else { return false }
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        return contains(text, in: [folder.name, folder.identity.path.displayPath, folder.identity.path.normalizedPath])
    }

    static func matches(_ item: MediaItem, query: LibrarySearchQuery) -> Bool {
        guard matchesIdentity(item.identity, query: query) else { return false }
        if !query.mediaKinds.isEmpty && !query.mediaKinds.contains(item.mediaKind) {
            return false
        }
        let text = query.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return true }
        return contains(text, in: [
            item.fileName,
            item.title,
            item.artist,
            item.album,
            item.genre,
            item.identity.path.displayPath,
            item.identity.path.normalizedPath
        ])
    }

    static func uuidString(_ uuid: UUID) -> String {
        uuid.uuidString.lowercased()
    }

    private static func folderArguments(
        _ folder: FolderItem,
        now: Double,
        includeCreatedAt: Bool
    ) throws -> StatementArguments {
        var arguments: StatementArguments = [
            "id": uuidString(folder.id.rawValue),
            "identity_key": folder.identity.stableKey,
            "identity_json": try encode(folder.identity),
            "source_id": uuidString(folder.identity.sourceID.rawValue),
            "share_id": uuidString(folder.identity.shareID.rawValue),
            "display_path": folder.identity.path.displayPath,
            "normalized_path": folder.identity.path.normalizedPath,
            "remote_file_id": folder.identity.remoteFileID?.rawValue,
            "size": folder.identity.size,
            "modified_at": folder.identity.modifiedAt?.timeIntervalSince1970,
            "parent_folder_id": folder.parentFolderID.map { uuidString($0.rawValue) },
            "name": folder.name,
            "scan_state": folder.scanState.rawValue,
            "sort_key": folder.sortKey,
            "failure_code": folder.failureCode,
            "updated_at": now
        ]
        if includeCreatedAt {
            arguments += ["created_at": now]
        }
        return arguments
    }

    private static func mediaItemArguments(
        _ item: MediaItem,
        now: Double,
        includeCreatedAt: Bool
    ) throws -> StatementArguments {
        var arguments: StatementArguments = [
            "id": uuidString(item.id.rawValue),
            "identity_key": item.identity.stableKey,
            "identity_json": try encode(item.identity),
            "source_id": uuidString(item.identity.sourceID.rawValue),
            "share_id": uuidString(item.identity.shareID.rawValue),
            "display_path": item.identity.path.displayPath,
            "normalized_path": item.identity.path.normalizedPath,
            "remote_file_id": item.identity.remoteFileID?.rawValue,
            "size": item.identity.size,
            "modified_at": item.identity.modifiedAt?.timeIntervalSince1970,
            "parent_folder_id": item.parentFolderID.map { uuidString($0.rawValue) },
            "media_kind": item.mediaKind.rawValue,
            "file_name": item.fileName,
            "title": item.title,
            "artist": item.artist,
            "album": item.album,
            "genre": item.genre,
            "track_number": item.trackNumber,
            "disc_number": item.discNumber,
            "duration": item.duration,
            "artwork_url": item.artworkURL?.absoluteString,
            "is_favorite": item.isFavorite ? 1 : 0,
            "sort_key": item.sortKey,
            "playback_capability_json": try optionalEncode(item.playbackCapability),
            "updated_at": now
        ]
        if includeCreatedAt {
            arguments += ["created_at": now]
        }
        return arguments
    }

    static func deleteMediaItems(sourceID: SourceID, in db: Database) throws {
        let source = uuidString(sourceID.rawValue)
        try db.execute(
            sql: """
            DELETE FROM media_search
            WHERE media_id IN (SELECT id FROM media_items WHERE source_id = ?)
            """,
            arguments: [source]
        )
        try db.execute(
            sql: """
            DELETE FROM cache_entries
            WHERE media_item_id IN (SELECT id FROM media_items WHERE source_id = ?)
            """,
            arguments: [source]
        )
        try db.execute(sql: "DELETE FROM media_items WHERE source_id = ?", arguments: [source])
        try db.execute(sql: "DELETE FROM folders WHERE source_id = ?", arguments: [source])
        try pruneOrphanedOverrides(in: db)
    }

    /// Delete only the source's media items whose identity_key is NOT in `keep`
    /// (plus their media_search + cache_entries rows), leaving surviving rows —
    /// and their PKs/cache_entries — intact. A temp table holds the keep set so
    /// we don't blow the SQLite bound-variable limit on a large library. Folders
    /// are left untouched (a now-empty folder is harmless; upsert maintains the
    /// live ones). An empty keep set deletes all of the source's items.
    static func deleteMediaItems(sourceID: SourceID, keeping keep: Set<String>, in db: Database) throws {
        let source = uuidString(sourceID.rawValue)
        try db.execute(sql: "CREATE TEMP TABLE IF NOT EXISTS _keep_identity_keys (k TEXT PRIMARY KEY)")
        try db.execute(sql: "DELETE FROM _keep_identity_keys")
        for key in keep {
            try db.execute(sql: "INSERT OR IGNORE INTO _keep_identity_keys (k) VALUES (?)", arguments: [key])
        }
        let absent = "source_id = ? AND identity_key NOT IN (SELECT k FROM _keep_identity_keys)"
        try db.execute(
            sql: "DELETE FROM media_search WHERE media_id IN (SELECT id FROM media_items WHERE \(absent))",
            arguments: [source]
        )
        try db.execute(
            sql: "DELETE FROM cache_entries WHERE media_item_id IN (SELECT id FROM media_items WHERE \(absent))",
            arguments: [source]
        )
        try db.execute(sql: "DELETE FROM media_items WHERE \(absent)", arguments: [source])
        try db.execute(sql: "DROP TABLE _keep_identity_keys")
        try pruneOrphanedOverrides(in: db)
    }

    static func deleteAllMediaItems(in db: Database) throws {
        try db.execute(sql: "DELETE FROM media_search")
        try db.execute(sql: "DELETE FROM cache_entries")
        try db.execute(sql: "DELETE FROM media_items")
        try db.execute(sql: "DELETE FROM folders")
        try db.execute(sql: "DELETE FROM metadata_overrides")
    }

    private static func folderExists(id: String, in db: Database) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT 1 FROM folders WHERE id = ?", arguments: [id]) != nil
    }

    private static func mediaItemExists(id: String, in db: Database) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT 1 FROM media_items WHERE id = ?", arguments: [id]) != nil
    }

    private static func playlistEntryTarget(_ target: PlaylistEntryTarget) -> (type: String, id: String, recursive: Bool) {
        switch target {
        case let .media(mediaItemID):
            return ("media", uuidString(mediaItemID.rawValue), false)
        case let .folder(folderID, recursive):
            return ("folder", uuidString(folderID.rawValue), recursive)
        }
    }

    private static func matchesIdentity(_ identity: RemoteItemIdentity, query: LibrarySearchQuery) -> Bool {
        if let sourceID = query.sourceID, identity.sourceID != sourceID {
            return false
        }
        if let shareID = query.shareID, identity.shareID != shareID {
            return false
        }
        return true
    }

    private static func contains(_ needle: String, in haystacks: [String?]) -> Bool {
        let normalizedNeedle = needle.localizedCaseInsensitiveCompare("") == .orderedSame
            ? needle
            : needle.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return haystacks.contains { value in
            value?
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
                .contains(normalizedNeedle) == true
        }
    }

    private static func encode<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .millisecondsSince1970
        let data = try encoder.encode(value)
        return String(decoding: data, as: UTF8.self)
    }

    private static func optionalEncode<T: Encodable>(_ value: T?) throws -> String? {
        guard let value else { return nil }
        return try encode(value)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from json: String) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return try decoder.decode(T.self, from: Data(json.utf8))
    }

    private static func uuid(_ value: String, table: String, column: String) throws -> UUID {
        guard let uuid = UUID(uuidString: value) else {
            throw MediaStoreError.invalidStoredValue(table: table, column: column, value: value)
        }
        return uuid
    }

    private static func sourceID(_ value: String, table: String, column: String) throws -> SourceID {
        try SourceID(rawValue: uuid(value, table: table, column: column))
    }

    private static func folderID(_ value: String, table: String, column: String) throws -> FolderID {
        try FolderID(rawValue: uuid(value, table: table, column: column))
    }

    private static func mediaItemID(_ value: String, table: String, column: String) throws -> MediaItemID {
        try MediaItemID(rawValue: uuid(value, table: table, column: column))
    }

    private static func playlistID(_ value: String, table: String, column: String) throws -> PlaylistID {
        try PlaylistID(rawValue: uuid(value, table: table, column: column))
    }

    private static func queueID(_ value: String, table: String, column: String) throws -> QueueID {
        try QueueID(rawValue: uuid(value, table: table, column: column))
    }

    private static func scanID(_ value: String, table: String, column: String) throws -> ScanID {
        try ScanID(rawValue: uuid(value, table: table, column: column))
    }
}
