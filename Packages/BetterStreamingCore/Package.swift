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
                "MetadataReader",
                "RemoteFileSystem",
                "SMBRemote",
                "WebDAVRemote",
                "FTPRemote",
                "SFTPRemote",
                "BetterStreamingSources",
                "MediaStore",
                "LibraryIndexer",
                "CacheManager",
                "PlaybackCore",
                "Diagnostics"
            ]
        ),
        .library(name: "BetterStreamingDomain", targets: ["BetterStreamingDomain"]),
        .library(name: "AppFoundation", targets: ["AppFoundation"]),
        .library(name: "MetadataReader", targets: ["MetadataReader"]),
        .library(name: "RemoteFileSystem", targets: ["RemoteFileSystem"]),
        .library(name: "SMBRemote", targets: ["SMBRemote"]),
        .library(name: "WebDAVRemote", targets: ["WebDAVRemote"]),
        .library(name: "FTPRemote", targets: ["FTPRemote"]),
        .library(name: "SFTPRemote", targets: ["SFTPRemote"]),
        .library(name: "BetterStreamingSources", targets: ["BetterStreamingSources"]),
        .library(name: "MediaStore", targets: ["MediaStore"]),
        .library(name: "LibraryIndexer", targets: ["LibraryIndexer"]),
        .library(name: "CacheManager", targets: ["CacheManager"]),
        .library(name: "PlaybackCore", targets: ["PlaybackCore"]),
        .library(name: "Diagnostics", targets: ["Diagnostics"]),
        .library(name: "TestSupport", targets: ["TestSupport"]),
        .executable(name: "LiveSMBProbe", targets: ["LiveSMBProbe"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.9.0"),
        // Vendored locally (copy of kishikawakatsumi/SMBClient 0.3.1) so we can
        // patch ByteReader to bounds-check instead of trapping (EXC_BREAKPOINT) on
        // a truncated/misframed SMB response. See Packages/SMBClient/.
        .package(path: "../SMBClient"),
        .package(url: "https://github.com/orlandos-nl/Citadel.git", from: "0.12.1"),
        // Mirrors Citadel's own swift-nio-ssh requirement so SFTPRemote can
        // import NIOSSH (host-key validation) without changing resolution.
        .package(url: "https://github.com/Wellz26/swift-nio-ssh.git", "0.3.4" ..< "0.4.0")
    ],
    targets: [
        .target(name: "BetterStreamingDomain"),
        .target(
            name: "AppFoundation",
            dependencies: ["BetterStreamingDomain"]
        ),
        .target(name: "MetadataReader"),
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
            name: "WebDAVRemote",
            dependencies: [
                "BetterStreamingDomain",
                "AppFoundation",
                "RemoteFileSystem"
            ]
        ),
        .target(
            name: "FTPRemote",
            dependencies: [
                "BetterStreamingDomain",
                "AppFoundation",
                "RemoteFileSystem"
            ]
        ),
        .target(
            name: "SFTPRemote",
            dependencies: [
                "BetterStreamingDomain",
                "AppFoundation",
                "RemoteFileSystem",
                .product(name: "Citadel", package: "Citadel"),
                .product(name: "NIOSSH", package: "swift-nio-ssh")
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
            name: "PlaybackCore",
            dependencies: [
                "BetterStreamingDomain",
                "AppFoundation",
                "CacheManager",
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
            name: "MetadataReaderTests",
            dependencies: ["MetadataReader"]
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
            name: "WebDAVRemoteTests",
            dependencies: ["WebDAVRemote"]
        ),
        .testTarget(
            name: "FTPRemoteTests",
            dependencies: ["FTPRemote"]
        ),
        .testTarget(
            name: "SFTPRemoteTests",
            dependencies: ["SFTPRemote"]
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
