import os

/// Shared os.Logger categories for app diagnostics — captured by `log stream`/
/// Console on device and simulator (unlike `print`), and redacted in Release so
/// user paths and titles don't leak to the system log. Marker and kind fields
/// are annotated `privacy: .public` so the `BETTERSTREAMING_` device-log filter
/// keeps working; user data stays at the default (private) redaction.
///
/// Mirrors the streaming logger in RemoteStreamingService (`streamLog`).
enum AppLog {
    private static let subsystem = "com.betterstreaming.app"

    static let library = Logger(subsystem: subsystem, category: "library")
    static let playback = Logger(subsystem: subsystem, category: "playback")
    static let ui = Logger(subsystem: subsystem, category: "ui")
    static let cache = Logger(subsystem: subsystem, category: "cache")
    static let source = Logger(subsystem: subsystem, category: "source")
}
