import Foundation

public struct EmbeddedArtwork: Equatable, Sendable {
    public var data: Data
    public var fileExtension: String
    public var mimeType: String?

    public init(data: Data, fileExtension: String, mimeType: String? = nil) {
        self.data = data
        self.fileExtension = fileExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        self.mimeType = mimeType
    }
}

public struct EmbeddedMediaMetadata: Equatable, Sendable {
    public var title: String?
    public var artist: String?
    public var album: String?
    public var genre: String?
    public var trackNumber: Int?
    public var discNumber: Int?
    public var durationSeconds: Double?
    public var artwork: EmbeddedArtwork?

    public init(
        title: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        genre: String? = nil,
        trackNumber: Int? = nil,
        discNumber: Int? = nil,
        durationSeconds: Double? = nil,
        artwork: EmbeddedArtwork? = nil
    ) {
        self.title = Self.clean(title)
        self.artist = Self.clean(artist)
        self.album = Self.clean(album)
        self.genre = Self.clean(genre)
        self.trackNumber = trackNumber
        self.discNumber = discNumber
        self.durationSeconds = durationSeconds
        self.artwork = artwork
    }

    public var isEmpty: Bool {
        title == nil
            && artist == nil
            && album == nil
            && genre == nil
            && trackNumber == nil
            && discNumber == nil
            && durationSeconds == nil
            && artwork == nil
    }

    mutating func mergeMissing(from other: EmbeddedMediaMetadata?) {
        guard let other else { return }
        title = title ?? other.title
        artist = artist ?? other.artist
        album = album ?? other.album
        genre = genre ?? other.genre
        trackNumber = trackNumber ?? other.trackNumber
        discNumber = discNumber ?? other.discNumber
        durationSeconds = durationSeconds ?? other.durationSeconds
        artwork = artwork ?? other.artwork
    }

    static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value
            .replacingOccurrences(of: "\u{0}", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

public enum EmbeddedMetadataReader {
    public static let defaultProbeLength = 256 * 1024

    public static func parse(_ data: Data, fileExtension: String = "") -> EmbeddedMediaMetadata {
        let bytes = [UInt8](data)
        let ext = fileExtension.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        var metadata = EmbeddedMediaMetadata()

        switch ext {
        case "mp3", "aac", "aiff", "aif":
            metadata.mergeMissing(from: parseID3(bytes))
        case "flac":
            metadata.mergeMissing(from: parseFLAC(bytes))
            metadata.mergeMissing(from: parseID3(bytes))
        case "m4a", "mp4", "m4v", "mov":
            metadata.mergeMissing(from: parseMP4(bytes))
            metadata.mergeMissing(from: parseID3(bytes))
        case "ogg", "opus":
            metadata.mergeMissing(from: parseOggVorbis(bytes))
        default:
            metadata.mergeMissing(from: parseID3(bytes))
            metadata.mergeMissing(from: parseFLAC(bytes))
            metadata.mergeMissing(from: parseMP4(bytes))
            metadata.mergeMissing(from: parseOggVorbis(bytes))
        }

        return metadata
    }
}

private extension EmbeddedMetadataReader {
    static func parseID3(_ bytes: [UInt8]) -> EmbeddedMediaMetadata? {
        guard bytes.count >= 10,
              bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33,
              let tagSize = readSyncSafe32(bytes, 6) else {
            return nil
        }

        let major = bytes[3]
        let tagEnd = min(bytes.count, 10 + tagSize)
        guard tagEnd > 10 else { return nil }

        var offset = 10
        var result = EmbeddedMediaMetadata()

        while offset < tagEnd {
            let frameID: String
            let frameSize: Int
            let contentStart: Int

            if major == 2 {
                guard offset + 6 <= tagEnd else { break }
                frameID = ascii(bytes, offset, 3)
                frameSize = readUInt24BE(bytes, offset + 3) ?? 0
                contentStart = offset + 6
            } else {
                guard offset + 10 <= tagEnd else { break }
                frameID = ascii(bytes, offset, 4)
                if major == 4 {
                    frameSize = readSyncSafe32(bytes, offset + 4) ?? 0
                } else {
                    frameSize = readUInt32BE(bytes, offset + 4) ?? 0
                }
                contentStart = offset + 10
            }

            guard frameID.allSatisfy({ $0.isLetter || $0.isNumber }),
                  frameSize > 0,
                  contentStart + frameSize <= tagEnd else {
                break
            }

            let content = Array(bytes[contentStart..<(contentStart + frameSize)])
            applyID3Frame(id: frameID, content: content, to: &result)
            offset = contentStart + frameSize
        }

        return result.isEmpty ? nil : result
    }

    static func applyID3Frame(id: String, content: [UInt8], to result: inout EmbeddedMediaMetadata) {
        if id == "APIC" {
            result.artwork = result.artwork ?? parseID3APIC(content)
            return
        }
        if id == "PIC" {
            result.artwork = result.artwork ?? parseID3PIC(content)
            return
        }
        guard let text = decodeID3Text(content) else { return }
        switch id {
        case "TIT2", "TT2":
            result.title = result.title ?? text
        case "TPE1", "TP1":
            result.artist = result.artist ?? text
        case "TPE2", "TP2":
            result.artist = result.artist ?? text
        case "TALB", "TAL":
            result.album = result.album ?? text
        case "TCON", "TCO":
            result.genre = result.genre ?? normalizedGenre(text)
        case "TRCK", "TRK":
            result.trackNumber = result.trackNumber ?? leadingNumber(text)
        case "TPOS", "TPA":
            result.discNumber = result.discNumber ?? leadingNumber(text)
        default:
            break
        }
    }

    static func parseID3APIC(_ content: [UInt8]) -> EmbeddedArtwork? {
        guard content.count > 4 else { return nil }
        let encoding = content[0]
        var offset = 1
        guard let mimeEnd = firstZero(in: content, from: offset) else { return nil }
        let mime = String(data: Data(content[offset..<mimeEnd]), encoding: .isoLatin1)
        offset = mimeEnd + 1
        guard offset < content.count else { return nil }
        offset += 1 // picture type
        offset = descriptionEndOffset(in: content, from: offset, encoding: encoding)
        guard offset < content.count else { return nil }
        return artwork(from: Array(content[offset..<content.count]), mimeType: mime)
    }

    static func parseID3PIC(_ content: [UInt8]) -> EmbeddedArtwork? {
        guard content.count > 6 else { return nil }
        let encoding = content[0]
        let imageFormat = String(data: Data(content[1..<4]), encoding: .isoLatin1)
        var offset = 5 // encoding + 3-byte image format + picture type
        offset = descriptionEndOffset(in: content, from: offset, encoding: encoding)
        guard offset < content.count else { return nil }
        return artwork(from: Array(content[offset..<content.count]), preferredExtension: imageFormat)
    }

    static func decodeID3Text(_ content: [UInt8]) -> String? {
        guard let encodingByte = content.first else { return nil }
        let payload = content.dropFirst()
        let decoded: String?
        switch encodingByte {
        case 0:
            decoded = String(data: Data(payload), encoding: .isoLatin1)
        case 1:
            decoded = String(data: Data(payload), encoding: .utf16)
        case 2:
            decoded = String(data: Data(payload), encoding: .utf16BigEndian)
        case 3:
            decoded = String(data: Data(payload), encoding: .utf8)
        default:
            decoded = String(data: Data(payload), encoding: .utf8)
        }
        return EmbeddedMediaMetadata.clean(decoded)
    }

    static func parseFLAC(_ bytes: [UInt8]) -> EmbeddedMediaMetadata? {
        guard let flacOffset = flacStart(in: bytes), flacOffset + 4 <= bytes.count else { return nil }
        var offset = flacOffset + 4
        var result = EmbeddedMediaMetadata()

        while offset + 4 <= bytes.count {
            let header = bytes[offset]
            let isLast = (header & 0x80) != 0
            let type = header & 0x7f
            guard let length = readUInt24BE(bytes, offset + 1) else { break }
            let blockStart = offset + 4
            let blockEnd = blockStart + length
            guard blockEnd <= bytes.count else { break }

            if type == 4 {
                result.mergeMissing(from: parseVorbisCommentBlock(Array(bytes[blockStart..<blockEnd])))
            } else if type == 6 {
                result.artwork = result.artwork ?? parseFLACPictureBlock(Array(bytes[blockStart..<blockEnd]))
            }
            if isLast { break }
            offset = blockEnd
        }

        return result.isEmpty ? nil : result
    }

    static func parseFLACPictureBlock(_ bytes: [UInt8]) -> EmbeddedArtwork? {
        var offset = 0
        guard offset + 8 <= bytes.count else { return nil }
        offset += 4 // picture type
        guard let mimeLength = readUInt32BE(bytes, offset) else { return nil }
        offset += 4
        guard offset + mimeLength <= bytes.count else { return nil }
        let mime = String(data: Data(bytes[offset..<(offset + mimeLength)]), encoding: .utf8)
        offset += mimeLength
        guard let descriptionLength = readUInt32BE(bytes, offset) else { return nil }
        offset += 4
        guard offset + descriptionLength <= bytes.count else { return nil }
        offset += descriptionLength
        guard offset + 20 <= bytes.count else { return nil }
        offset += 16 // width, height, depth, indexed colours
        guard let dataLength = readUInt32BE(bytes, offset) else { return nil }
        offset += 4
        guard offset + dataLength <= bytes.count else { return nil }
        return artwork(from: Array(bytes[offset..<(offset + dataLength)]), mimeType: mime)
    }

    static func flacStart(in bytes: [UInt8]) -> Int? {
        if startsWith(bytes, pattern: [0x66, 0x4c, 0x61, 0x43], at: 0) { return 0 }
        guard bytes.count >= 10,
              bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33,
              let tagSize = readSyncSafe32(bytes, 6) else {
            return nil
        }
        let offset = 10 + tagSize
        return startsWith(bytes, pattern: [0x66, 0x4c, 0x61, 0x43], at: offset) ? offset : nil
    }

    static func parseOggVorbis(_ bytes: [UInt8]) -> EmbeddedMediaMetadata? {
        if let marker = firstIndex(of: Array("OpusTags".utf8), in: bytes) {
            return parseVorbisCommentBlock(Array(bytes[(marker + 8)..<bytes.count]))
        }
        if let marker = firstIndex(of: [0x03] + Array("vorbis".utf8), in: bytes) {
            return parseVorbisCommentBlock(Array(bytes[(marker + 7)..<bytes.count]))
        }
        return nil
    }

    static func parseVorbisCommentBlock(_ bytes: [UInt8]) -> EmbeddedMediaMetadata? {
        var offset = 0
        guard let vendorLength = readUInt32LE(bytes, offset) else { return nil }
        offset += 4 + vendorLength
        guard offset + 4 <= bytes.count,
              let commentCount = readUInt32LE(bytes, offset) else {
            return nil
        }
        offset += 4

        var result = EmbeddedMediaMetadata()
        for _ in 0..<commentCount {
            guard offset + 4 <= bytes.count,
                  let length = readUInt32LE(bytes, offset) else {
                break
            }
            offset += 4
            guard offset + length <= bytes.count else { break }
            if let comment = String(data: Data(bytes[offset..<(offset + length)]), encoding: .utf8) {
                applyVorbisComment(comment, to: &result)
            }
            offset += length
        }

        return result.isEmpty ? nil : result
    }

    static func applyVorbisComment(_ comment: String, to result: inout EmbeddedMediaMetadata) {
        let parts = comment.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { return }
        let key = parts[0].uppercased()
        let value = EmbeddedMediaMetadata.clean(String(parts[1]))
        switch key {
        case "TITLE":
            result.title = result.title ?? value
        case "ARTIST", "ALBUMARTIST", "ALBUM ARTIST":
            result.artist = result.artist ?? value
        case "ALBUM":
            result.album = result.album ?? value
        case "GENRE":
            result.genre = result.genre ?? value
        case "TRACKNUMBER":
            result.trackNumber = result.trackNumber ?? leadingNumber(value)
        case "DISCNUMBER", "DISKNUMBER":
            result.discNumber = result.discNumber ?? leadingNumber(value)
        case "METADATA_BLOCK_PICTURE":
            if let value,
               let data = Data(base64Encoded: value, options: [.ignoreUnknownCharacters]) {
                result.artwork = result.artwork ?? parseFLACPictureBlock([UInt8](data))
            }
        case "COVERART":
            if let value,
               let data = Data(base64Encoded: value, options: [.ignoreUnknownCharacters]) {
                result.artwork = result.artwork ?? artwork(from: [UInt8](data))
            }
        default:
            break
        }
    }

    static func parseMP4(_ bytes: [UInt8]) -> EmbeddedMediaMetadata? {
        var result = EmbeddedMediaMetadata()
        parseMP4Atoms(bytes, start: 0, end: bytes.count, inIlst: false, result: &result, depth: 0)
        return result.isEmpty ? nil : result
    }

    static func parseMP4Atoms(
        _ bytes: [UInt8],
        start: Int,
        end: Int,
        inIlst: Bool,
        result: inout EmbeddedMediaMetadata,
        depth: Int
    ) {
        guard depth < 8 else { return }
        var offset = start

        while offset + 8 <= end {
            guard let atom = readAtom(bytes, offset: offset, containerEnd: end) else { break }
            if inIlst {
                parseMP4Tag(type: atom.type, bytes: bytes, start: atom.dataStart, end: atom.end, result: &result)
            } else if atom.type == "ilst" {
                parseMP4Atoms(bytes, start: atom.dataStart, end: atom.end, inIlst: true, result: &result, depth: depth + 1)
            } else if atom.type == "moov" || atom.type == "udta" {
                parseMP4Atoms(bytes, start: atom.dataStart, end: atom.end, inIlst: false, result: &result, depth: depth + 1)
            } else if atom.type == "meta" {
                let childStart = min(atom.dataStart + 4, atom.end)
                parseMP4Atoms(bytes, start: childStart, end: atom.end, inIlst: false, result: &result, depth: depth + 1)
            }
            offset = atom.end
        }
    }

    static func parseMP4Tag(
        type: String,
        bytes: [UInt8],
        start: Int,
        end: Int,
        result: inout EmbeddedMediaMetadata
    ) {
        guard ["©nam", "©ART", "aART", "©alb", "©gen", "gnre", "trkn", "disk", "covr"].contains(type) else { return }
        var offset = start
        while offset + 8 <= end {
            guard let atom = readAtom(bytes, offset: offset, containerEnd: end) else { break }
            if atom.type == "data" {
                let dataType = readUInt32BE(bytes, atom.dataStart) ?? 0
                let payloadStart = atom.dataStart + 8
                guard payloadStart <= atom.end else { return }
                let payload = Array(bytes[payloadStart..<atom.end])
                applyMP4Tag(type: type, payload: payload, dataType: dataType, to: &result)
                return
            }
            offset = atom.end
        }
    }

    static func applyMP4Tag(type: String, payload: [UInt8], dataType: Int, to result: inout EmbeddedMediaMetadata) {
        switch type {
        case "©nam":
            result.title = result.title ?? text(payload)
        case "©ART", "aART":
            result.artist = result.artist ?? text(payload)
        case "©alb":
            result.album = result.album ?? text(payload)
        case "©gen":
            result.genre = result.genre ?? text(payload)
        case "gnre":
            if let value = readUInt16BE(payload, 0), value > 0 {
                result.genre = result.genre ?? id3Genre(Int(value - 1))
            }
        case "trkn":
            if payload.count >= 4 {
                result.trackNumber = result.trackNumber ?? readUInt16BE(payload, 2).map(Int.init)
            }
        case "disk":
            if payload.count >= 4 {
                result.discNumber = result.discNumber ?? readUInt16BE(payload, 2).map(Int.init)
            }
        case "covr":
            let preferredExtension: String?
            switch dataType {
            case 13: preferredExtension = "jpg"
            case 14: preferredExtension = "png"
            default: preferredExtension = nil
            }
            result.artwork = result.artwork ?? artwork(from: payload, preferredExtension: preferredExtension)
        default:
            break
        }
    }

    struct Atom {
        let type: String
        let dataStart: Int
        let end: Int
    }

    static func readAtom(_ bytes: [UInt8], offset: Int, containerEnd: Int) -> Atom? {
        guard offset + 8 <= containerEnd,
              let size32 = readUInt32BE(bytes, offset) else {
            return nil
        }
        let type = fourCC(bytes, offset + 4)
        let headerSize: Int
        let size: Int
        // `remaining` is the space left in the container; it is always >= 8 here
        // (offset + 8 <= containerEnd) and can never overflow, unlike offset+size.
        let remaining = containerEnd - offset
        if size32 == 1 {
            // 64-bit extended size. On 64-bit platforms Int.max == Int64.max, so
            // the old `size64 <= Int64(Int.max)` guard never rejected anything and
            // `offset + size` could overflow and trap. Bound against `remaining`.
            guard offset + 16 <= containerEnd,
                  let size64 = readUInt64BE(bytes, offset + 8),
                  size64 >= 0,
                  size64 <= Int64(remaining) else {
                return nil
            }
            headerSize = 16
            size = Int(size64)
        } else if size32 == 0 {
            headerSize = 8
            size = remaining
        } else {
            headerSize = 8
            size = size32
        }
        // No unchecked addition: validate against remaining space first.
        guard size >= headerSize, size <= remaining else { return nil }
        let end = offset + size   // safe: size <= remaining => end <= containerEnd
        return Atom(type: type, dataStart: offset + headerSize, end: end)
    }

    static func normalizedGenre(_ value: String) -> String? {
        guard var cleaned = EmbeddedMediaMetadata.clean(value) else { return nil }
        if cleaned.hasPrefix("("), let close = cleaned.firstIndex(of: ")") {
            let numberText = String(cleaned[cleaned.index(after: cleaned.startIndex)..<close])
            if let number = Int(numberText), let genre = id3Genre(number) {
                return genre
            }
            cleaned.removeSubrange(cleaned.startIndex...close)
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let number = Int(cleaned), let genre = id3Genre(number) {
            return genre
        }
        return EmbeddedMediaMetadata.clean(cleaned)
    }

    static func leadingNumber(_ value: String?) -> Int? {
        guard let value = EmbeddedMediaMetadata.clean(value) else { return nil }
        let digits = value.prefix(while: { $0.isNumber })
        return digits.isEmpty ? nil : Int(digits)
    }

    static func text(_ bytes: [UInt8]) -> String? {
        EmbeddedMediaMetadata.clean(String(data: Data(bytes), encoding: .utf8))
            ?? EmbeddedMediaMetadata.clean(String(data: Data(bytes), encoding: .utf16))
            ?? EmbeddedMediaMetadata.clean(latin1(bytes))
    }

    static func artwork(
        from bytes: [UInt8],
        mimeType: String? = nil,
        preferredExtension: String? = nil
    ) -> EmbeddedArtwork? {
        guard !bytes.isEmpty else { return nil }
        let ext = normalizedImageExtension(preferredExtension)
            ?? imageExtension(forMIMEType: mimeType)
            ?? sniffedImageExtension(bytes)
        guard let ext else { return nil }
        return EmbeddedArtwork(
            data: Data(bytes),
            fileExtension: ext,
            mimeType: normalizedImageMIMEType(mimeType, fileExtension: ext)
        )
    }

    static func descriptionEndOffset(in bytes: [UInt8], from start: Int, encoding: UInt8) -> Int {
        guard start < bytes.count else { return bytes.count }
        if encoding == 1 || encoding == 2 {
            var offset = start
            while offset + 1 < bytes.count {
                if bytes[offset] == 0, bytes[offset + 1] == 0 {
                    return offset + 2
                }
                offset += 2
            }
            return bytes.count
        }
        guard let end = firstZero(in: bytes, from: start) else { return bytes.count }
        return end + 1
    }

    static func firstZero(in bytes: [UInt8], from start: Int) -> Int? {
        guard start < bytes.count else { return nil }
        for offset in start..<bytes.count where bytes[offset] == 0 {
            return offset
        }
        return nil
    }

    static func imageExtension(forMIMEType mimeType: String?) -> String? {
        guard let mimeType = EmbeddedMediaMetadata.clean(mimeType)?.lowercased() else { return nil }
        switch mimeType {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        case "image/bmp", "image/x-ms-bmp": return "bmp"
        default:
            guard mimeType.hasPrefix("image/") else { return nil }
            return normalizedImageExtension(String(mimeType.dropFirst("image/".count)))
        }
    }

    static func normalizedImageMIMEType(_ mimeType: String?, fileExtension: String) -> String? {
        if let mimeType = EmbeddedMediaMetadata.clean(mimeType), mimeType.lowercased().hasPrefix("image/") {
            return mimeType
        }
        switch fileExtension {
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "bmp": return "image/bmp"
        default: return nil
        }
    }

    static func normalizedImageExtension(_ value: String?) -> String? {
        guard let value = EmbeddedMediaMetadata.clean(value)?.lowercased() else { return nil }
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        switch trimmed {
        case "jpg", "jpeg", "jfif": return "jpg"
        case "png": return "png"
        case "gif": return "gif"
        case "webp": return "webp"
        case "bmp": return "bmp"
        default: return nil
        }
    }

    static func sniffedImageExtension(_ bytes: [UInt8]) -> String? {
        if bytes.count >= 3, bytes[0] == 0xff, bytes[1] == 0xd8, bytes[2] == 0xff {
            return "jpg"
        }
        if startsWith(bytes, pattern: [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a], at: 0) {
            return "png"
        }
        if startsWith(bytes, pattern: Array("GIF87a".utf8), at: 0)
            || startsWith(bytes, pattern: Array("GIF89a".utf8), at: 0) {
            return "gif"
        }
        if bytes.count >= 12,
           startsWith(bytes, pattern: Array("RIFF".utf8), at: 0),
           startsWith(bytes, pattern: Array("WEBP".utf8), at: 8) {
            return "webp"
        }
        if startsWith(bytes, pattern: Array("BM".utf8), at: 0) {
            return "bmp"
        }
        return nil
    }

    static func latin1(_ bytes: [UInt8]) -> String {
        let scalars = bytes.map { UnicodeScalar(Int($0))! }
        return String(String.UnicodeScalarView(scalars))
    }

    static func ascii(_ bytes: [UInt8], _ offset: Int, _ count: Int) -> String {
        guard offset + count <= bytes.count else { return "" }
        return String(bytes: bytes[offset..<(offset + count)], encoding: .ascii) ?? ""
    }

    static func fourCC(_ bytes: [UInt8], _ offset: Int) -> String {
        guard offset + 4 <= bytes.count else { return "" }
        return latin1(Array(bytes[offset..<(offset + 4)]))
    }

    static func startsWith(_ bytes: [UInt8], pattern: [UInt8], at offset: Int) -> Bool {
        guard offset >= 0, offset + pattern.count <= bytes.count else { return false }
        return Array(bytes[offset..<(offset + pattern.count)]) == pattern
    }

    static func firstIndex(of pattern: [UInt8], in bytes: [UInt8]) -> Int? {
        guard !pattern.isEmpty, bytes.count >= pattern.count else { return nil }
        for offset in 0...(bytes.count - pattern.count) where startsWith(bytes, pattern: pattern, at: offset) {
            return offset
        }
        return nil
    }

    static func readSyncSafe32(_ bytes: [UInt8], _ offset: Int) -> Int? {
        guard offset + 4 <= bytes.count else { return nil }
        return (Int(bytes[offset] & 0x7f) << 21)
            | (Int(bytes[offset + 1] & 0x7f) << 14)
            | (Int(bytes[offset + 2] & 0x7f) << 7)
            | Int(bytes[offset + 3] & 0x7f)
    }

    static func readUInt16BE(_ bytes: [UInt8], _ offset: Int) -> UInt16? {
        guard offset + 2 <= bytes.count else { return nil }
        return (UInt16(bytes[offset]) << 8) | UInt16(bytes[offset + 1])
    }

    static func readUInt24BE(_ bytes: [UInt8], _ offset: Int) -> Int? {
        guard offset + 3 <= bytes.count else { return nil }
        return (Int(bytes[offset]) << 16) | (Int(bytes[offset + 1]) << 8) | Int(bytes[offset + 2])
    }

    static func readUInt32BE(_ bytes: [UInt8], _ offset: Int) -> Int? {
        guard offset + 4 <= bytes.count else { return nil }
        let value = (UInt32(bytes[offset]) << 24)
            | (UInt32(bytes[offset + 1]) << 16)
            | (UInt32(bytes[offset + 2]) << 8)
            | UInt32(bytes[offset + 3])
        return Int(value)
    }

    static func readUInt64BE(_ bytes: [UInt8], _ offset: Int) -> Int64? {
        guard offset + 8 <= bytes.count else { return nil }
        var value: UInt64 = 0
        for byte in bytes[offset..<(offset + 8)] {
            value = (value << 8) | UInt64(byte)
        }
        return value <= UInt64(Int64.max) ? Int64(value) : nil
    }

    static func readUInt32LE(_ bytes: [UInt8], _ offset: Int) -> Int? {
        guard offset + 4 <= bytes.count else { return nil }
        let value = UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
        return Int(value)
    }

    static func id3Genre(_ index: Int) -> String? {
        guard index >= 0, index < id3Genres.count else { return nil }
        return id3Genres[index]
    }

    static let id3Genres = [
        "Blues", "Classic Rock", "Country", "Dance", "Disco", "Funk", "Grunge",
        "Hip-Hop", "Jazz", "Metal", "New Age", "Oldies", "Other", "Pop",
        "R&B", "Rap", "Reggae", "Rock", "Techno", "Industrial", "Alternative",
        "Ska", "Death Metal", "Pranks", "Soundtrack", "Euro-Techno", "Ambient",
        "Trip-Hop", "Vocal", "Jazz+Funk", "Fusion", "Trance", "Classical",
        "Instrumental", "Acid", "House", "Game", "Sound Clip", "Gospel",
        "Noise", "AlternRock", "Bass", "Soul", "Punk", "Space", "Meditative",
        "Instrumental Pop", "Instrumental Rock", "Ethnic", "Gothic",
        "Darkwave", "Techno-Industrial", "Electronic", "Pop-Folk", "Eurodance",
        "Dream", "Southern Rock", "Comedy", "Cult", "Gangsta", "Top 40",
        "Christian Rap", "Pop/Funk", "Jungle", "Native American", "Cabaret",
        "New Wave", "Psychadelic", "Rave", "Showtunes", "Trailer", "Lo-Fi",
        "Tribal", "Acid Punk", "Acid Jazz", "Polka", "Retro", "Musical",
        "Rock & Roll", "Hard Rock"
    ]
}
