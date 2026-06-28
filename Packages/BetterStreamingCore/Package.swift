// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "BetterStreamingCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "BetterStreamingCore",
            targets: [
                "BetterStreamingDomain",
                "AppFoundation",
                "RemoteFileSystem",
                "SMBRemote",
                "BetterStreamingSources",
                "MediaStore",
                "LibraryIndexer",
                "CacheManager",
                "StreamBridge",
                "PlaybackCore",
                "PlaylistCore",
                "MetadataCore",
                "Diagnostics"
            ]
        ),
        .library(name: "BetterStreamingDomain", targets: ["BetterStreamingDomain"]),
        .library(name: "AppFoundation", targets: ["AppFoundation"]),
        .library(name: "RemoteFileSystem", targets: ["RemoteFileSystem"]),
        .library(name: "SMBRemote", targets: ["SMBRemote"]),
        .library(name: "BetterStreamingSources", targets: ["BetterStreamingSources"]),
        .library(name: "MediaStore", targets: ["MediaStore"]),
        .library(name: "LibraryIndexer", targets: ["LibraryIndexer"]),
        .library(name: "CacheManager", targets: ["CacheManager"]),
        .library(name: "StreamBridge", targets: ["StreamBridge"]),
        .library(name: "PlaybackCore", targets: ["PlaybackCore"]),
        .library(name: "PlaylistCore", targets: ["PlaylistCore"]),
        .library(name: "MetadataCore", targets: ["MetadataCore"]),
        .library(name: "Diagnostics", targets: ["Diagnostics"]),
        .library(name: "TestSupport", targets: ["TestSupport"]),
        .executable(name: "LiveSMBProbe", targets: ["LiveSMBProbe"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.9.0"),
        .package(url: "https://github.com/kishikawakatsumi/SMBClient.git", from: "0.3.1")
    ],
    targets: [
        .target(name: "BetterStreamingDomain"),
        .target(
            name: "AppFoundation",
            dependencies: ["BetterStreamingDomain"]
        ),
        .target(
            name: "RemoteFileSystem",
            dependencies: ["BetterStreamingDomain", "AppFoundation"]
        ),
        .target(
            name: "SMBRemote",
            dependencies: [
                "BetterStreamingDomain",
                "AppFoundation",
                "RemoteFileSystem",
                .product(name: "SMBClient", package: "SMBClient")
            ]
        ),
        .target(
            name: "BetterStreamingSources",
            dependencies: [
                "BetterStreamingDomain",
                "AppFoundation",
                "RemoteFileSystem",
                "SMBRemote"
            ]
        ),
        .target(
            name: "MediaStore",
            dependencies: [
                "BetterStreamingDomain",
                "AppFoundation",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .target(
            name: "LibraryIndexer",
            dependencies: [
                "BetterStreamingDomain",
                "AppFoundation",
                "RemoteFileSystem",
                "MediaStore"
            ]
        ),
        .target(
            name: "CacheManager",
            dependencies: [
                "BetterStreamingDomain",
                "AppFoundation",
                "RemoteFileSystem",
                "MediaStore"
            ]
        ),
        .target(
            name: "StreamBridge",
            dependencies: [
                "BetterStreamingDomain",
                "AppFoundation",
                "RemoteFileSystem",
                "CacheManager"
            ]
        ),
        .target(
            name: "PlaybackCore",
            dependencies: [
                "BetterStreamingDomain",
                "AppFoundation",
                "CacheManager",
                "MediaStore"
            ]
        ),
        .target(
            name: "PlaylistCore",
            dependencies: [
                "BetterStreamingDomain",
                "AppFoundation",
                "MediaStore"
            ]
        ),
        .target(
            name: "MetadataCore",
            dependencies: [
                "BetterStreamingDomain",
                "AppFoundation",
                "MediaStore"
            ]
        ),
        .target(
            name: "Diagnostics",
            dependencies: ["BetterStreamingDomain", "AppFoundation"]
        ),
        .target(
            name: "TestSupport",
            dependencies: [
                "BetterStreamingDomain",
                "AppFoundation",
                "RemoteFileSystem"
            ]
        ),
        .executableTarget(
            name: "LiveSMBProbe",
            dependencies: [
                "BetterStreamingDomain",
                "RemoteFileSystem",
                "SMBRemote",
                "LibraryIndexer"
            ]
        ),
        .testTarget(
            name: "BetterStreamingDomainTests",
            dependencies: ["BetterStreamingDomain"]
        ),
        .testTarget(
            name: "RemoteFileSystemTests",
            dependencies: ["RemoteFileSystem", "TestSupport"]
        ),
        .testTarget(
            name: "SMBRemoteIntegrationTests",
            dependencies: ["SMBRemote"]
        ),
        .testTarget(
            name: "MediaStoreTests",
            dependencies: ["MediaStore"]
        ),
        .testTarget(
            name: "LibraryIndexerTests",
            dependencies: ["LibraryIndexer", "TestSupport"]
        ),
        .testTarget(
            name: "CacheManagerTests",
            dependencies: ["CacheManager", "TestSupport"]
        ),
        .testTarget(
            name: "PlaybackCoreTests",
            dependencies: ["PlaybackCore"]
        ),
        .testTarget(
            name: "DiagnosticsTests",
            dependencies: ["Diagnostics"]
        )
    ]
)
