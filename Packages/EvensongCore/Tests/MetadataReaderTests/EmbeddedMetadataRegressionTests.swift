import Foundation
import MetadataReader
import Testing

// MARK: - ID3 per-frame format flags (v2.3 / v2.4)

@Test func id3v24FrameLevelUnsyncIsReversed() {
    // v2.4 frame with the unsynchronisation format flag (0x02). The stored body
    // has a 0x00 stuffed after 0xFF; de-unsync must restore it before decoding.
    let content: [UInt8] = [0x00 /* Latin-1 */, 0xFF, 0x00 /* stuffed */]
    let frame = Array("TIT2".utf8) + syncSafe(content.count) + [0x00, 0x02] + content
    let data = Data(Array("ID3".utf8) + [4, 0, 0] + syncSafe(frame.count) + frame)

    let metadata = EmbeddedMetadataReader.parse(data, fileExtension: "mp3")
    #expect(metadata.title == "ÿ")   // 0xFF as Latin-1
}

@Test func id3v24DataLengthIndicatorIsSkipped() {
    // Format flag 0x01 prepends a 4-byte sync-safe data length before the payload.
    let payload: [UInt8] = [0x03 /* utf-8 */] + Array("Hi".utf8)
    let content = syncSafe(payload.count) + payload
    let frame = Array("TIT2".utf8) + syncSafe(content.count) + [0x00, 0x01] + content
    let data = Data(Array("ID3".utf8) + [4, 0, 0] + syncSafe(frame.count) + frame)

    let metadata = EmbeddedMetadataReader.parse(data, fileExtension: "mp3")
    #expect(metadata.title == "Hi")
}

@Test func id3CompressedFrameIsDroppedNotDecodedAsMojibake() {
    let garbage: [UInt8] = [0x03] + [0x1f, 0x8b, 0x08, 0x00, 0x99]   // fake compressed bytes
    let titleFrame = Array("TIT2".utf8) + syncSafe(garbage.count) + [0x00, 0x08 /* compressed */] + garbage
    let artistPayload: [UInt8] = [0x03] + Array("Real Artist".utf8)
    let artistFrame = Array("TPE1".utf8) + syncSafe(artistPayload.count) + [0x00, 0x00] + artistPayload
    let body = titleFrame + artistFrame
    let data = Data(Array("ID3".utf8) + [4, 0, 0] + syncSafe(body.count) + body)

    let metadata = EmbeddedMetadataReader.parse(data, fileExtension: "mp3")
    #expect(metadata.title == nil)
    #expect(metadata.artist == "Real Artist")
}

// MARK: - Global unsync / extended header / offset ID3 start

@Test func id3v23GlobalUnsyncIsReversed() {
    let content: [UInt8] = [0x00 /* Latin-1 */, 0xFF]   // ÿ
    let frame = Array("TIT2".utf8) + uint32BE(content.count) + [0x00, 0x00] + content
    let unsynced = unsynchronise(frame)
    let data = Data(Array("ID3".utf8) + [3, 0, 0x80 /* global unsync */] + syncSafe(unsynced.count) + unsynced)

    let metadata = EmbeddedMetadataReader.parse(data, fileExtension: "mp3")
    #expect(metadata.title == "ÿ")
}

@Test func id3v23ExtendedHeaderIsSkipped() {
    let extData: [UInt8] = [0, 0, 0, 0, 0, 0]   // 6 bytes of extended-header payload
    let ext = uint32BE(extData.count) + extData
    let framePayload: [UInt8] = [0x03] + Array("After Ext".utf8)
    let frame = Array("TIT2".utf8) + uint32BE(framePayload.count) + [0x00, 0x00] + framePayload
    let body = ext + frame
    let data = Data(Array("ID3".utf8) + [3, 0, 0x40 /* extended header */] + syncSafe(body.count) + body)

    let metadata = EmbeddedMetadataReader.parse(data, fileExtension: "mp3")
    #expect(metadata.title == "After Ext")
}

@Test func id3TagFoundAtNonZeroOffset() {
    let framePayload: [UInt8] = [0x03] + Array("Chunked".utf8)
    let frame = Array("TIT2".utf8) + uint32BE(framePayload.count) + [0x00, 0x00] + framePayload
    let tag = Array("ID3".utf8) + [3, 0, 0] + syncSafe(frame.count) + frame
    let data = Data([0, 1, 2, 3, 4, 5, 6, 7] + tag)   // ID3 not at byte 0 (AIFF/AAC chunk)

    let metadata = EmbeddedMetadataReader.parse(data, fileExtension: "aiff")
    #expect(metadata.title == "Chunked")
}

// MARK: - Encodings and genre map

@Test func id3Latin1FramePrefersWindows1251ForCyrillic() {
    // cp1251 bytes that are Cyrillic letters but non-letters in Latin-1, so the
    // letter-count heuristic must pick Windows-1251.
    let content: [UInt8] = [0x00 /* Latin-1 tag */, 0xA8, 0xB8]   // Ёё in cp1251
    let frame = Array("TIT2".utf8) + uint32BE(content.count) + [0x00, 0x00] + content
    let data = Data(Array("ID3".utf8) + [3, 0, 0] + syncSafe(frame.count) + frame)

    let metadata = EmbeddedMetadataReader.parse(data, fileExtension: "mp3")
    #expect(metadata.title == "Ёё")
}

@Test func id3GenreNumericWinampExtensionsResolve() {
    #expect(genre(for: "(137)") == "Heavy Metal")
    #expect(genre(for: "(190)") == "Garage Rock")
}

@Test func id3v24SyncSafeFrameSizeIsRespected() {
    // A frame whose size has a high bit set: read as a plain uint32 it would be
    // wrong, so the parser must use the sync-safe interpretation.
    let title = String(repeating: "a", count: 130)
    let payload: [UInt8] = [0x03] + Array(title.utf8)   // 131 bytes, > 127
    let frame = Array("TIT2".utf8) + syncSafe(payload.count) + [0x00, 0x00] + payload
    let data = Data(Array("ID3".utf8) + [4, 0, 0] + syncSafe(frame.count) + frame)

    let metadata = EmbeddedMetadataReader.parse(data, fileExtension: "mp3")
    #expect(metadata.title == title)
}

// MARK: - ID3v2.2 PIC

@Test func id3v22PICPictureIsParsed() {
    let image = jpegBytes()
    let content: [UInt8] = [0x00 /* encoding */] + Array("JPG".utf8) + [0x00 /* type */, 0x00 /* empty desc */] + image
    let frame = Array("PIC".utf8) + uint24BE(content.count) + content
    let data = Data(Array("ID3".utf8) + [2, 0, 0] + syncSafe(frame.count) + frame)

    let metadata = EmbeddedMetadataReader.parse(data, fileExtension: "mp3")
    #expect(metadata.artwork?.fileExtension == "jpg")
    #expect(metadata.artwork?.data == Data(image))
}

// MARK: - Opus

@Test func opusTagsCommentsAreParsed() {
    let comments = vorbisComments(["TITLE": "Opus Title", "ARTIST": "Opus Artist"])
    let data = Data(Array("OpusHead".utf8) + [0] + Array("OpusTags".utf8) + comments)

    let metadata = EmbeddedMetadataReader.parse(data, fileExtension: "opus")
    #expect(metadata.title == "Opus Title")
    #expect(metadata.artist == "Opus Artist")
}

// MARK: - FLAC artwork byte range

@Test func flacArtworkByteRangeAndSeparateParse() {
    let image = jpegBytes()
    let picture = flacPictureBlock(mimeType: "image/jpeg", image: image)
    let block = metadataBlock(type: 6, payload: picture, isLast: true)
    let probe = Array("fLaC".utf8) + block

    let range = EmbeddedMetadataReader.artworkByteRange(probe: probe, fileExtension: "flac")
    #expect(range?.lowerBound == 8)                 // fLaC(4) + block header(4)
    #expect(range?.count == picture.count)

    if let range {
        let art = EmbeddedMetadataReader.parseFLACPicture(Array(probe[range]))
        #expect(art?.data == Data(image))
    }
}

// MARK: - MP4 64-bit size overflow guard

@Test func mp4OversizedExtendedAtomDoesNotTrap() {
    // size32 == 1 signals a 64-bit size; an absurd value must be rejected (nil),
    // never used in an unchecked `offset + size` that would overflow/trap.
    var bytes = uint32BE(1) + Array("moov".utf8)
    bytes += uint64BE(Int64.max)
    let data = Data(bytes)

    let metadata = EmbeddedMetadataReader.parse(data, fileExtension: "m4a")
    #expect(metadata.title == nil)   // no crash, no bogus data
}

// MARK: - MP4 moov at end of file (non-faststart)

@Test func mp4MoovAtEndTailRangeAndParse() {
    let ftyp = atom("ftyp", Array("M4A ".utf8))
    let mdat = atom("mdat", [UInt8](repeating: 0, count: 100))
    let ilst = atom("ilst", atom([0xa9, 0x6e, 0x61, 0x6d], dataAtom("Tail Title")))
    let moov = atom("moov", atom("udta", atom("meta", [0, 0, 0, 0] + ilst)))
    let full = ftyp + mdat + moov
    let moovOffset = ftyp.count + mdat.count

    // Head probe covers only ftyp + the mdat header (moov is entirely beyond it).
    let head = Array(full.prefix(30))
    let range = EmbeddedMetadataReader.mp4MetadataTailRange(head: head, fileLength: Int64(full.count))
    #expect(range?.lowerBound == Int64(moovOffset))
    #expect(range?.upperBound == Int64(full.count))

    if let range {
        let tail = Data(full[Int(range.lowerBound)..<Int(range.upperBound)])
        let metadata = EmbeddedMetadataReader.parse(head: Data(head), tail: tail, fileExtension: "m4a")
        #expect(metadata.title == "Tail Title")
    }
}

@Test func mp4MoovInHeadNeedsNoTail() {
    let ftyp = atom("ftyp", Array("M4A ".utf8))
    let ilst = atom("ilst", atom([0xa9, 0x6e, 0x61, 0x6d], dataAtom("Front Title")))
    let moov = atom("moov", atom("udta", atom("meta", [0, 0, 0, 0] + ilst)))
    let full = ftyp + moov

    #expect(EmbeddedMetadataReader.mp4MetadataTailRange(head: full, fileLength: Int64(full.count)) == nil)
}

@Test func mp4TailRangeIgnoresNonMP4Input() {
    let notMP4 = Array("ID3".utf8) + [3, 0, 0, 0, 0, 0, 0]
    #expect(EmbeddedMetadataReader.mp4MetadataTailRange(head: notMP4, fileLength: 1000) == nil)
}

// MARK: - Fixture builders

private func genre(for value: String) -> String? {
    let payload = [UInt8(0)] + Array(value.utf8)
    let frame = Array("TCON".utf8) + uint32BE(payload.count) + [0, 0] + payload
    let data = Data(Array("ID3".utf8) + [3, 0, 0] + syncSafe(frame.count) + frame)
    return EmbeddedMetadataReader.parse(data, fileExtension: "mp3").genre
}

/// Insert a 0x00 after every 0xFF (ID3 unsynchronisation).
private func unsynchronise(_ bytes: [UInt8]) -> [UInt8] {
    var out: [UInt8] = []
    for byte in bytes {
        out.append(byte)
        if byte == 0xFF { out.append(0x00) }
    }
    return out
}

private func syncSafe(_ value: Int) -> [UInt8] {
    [
        UInt8((value >> 21) & 0x7f),
        UInt8((value >> 14) & 0x7f),
        UInt8((value >> 7) & 0x7f),
        UInt8(value & 0x7f)
    ]
}

private func vorbisComments(_ comments: [String: String]) -> [UInt8] {
    var bytes = uint32LE(0)
    bytes += uint32LE(comments.count)
    for (key, value) in comments {
        let comment = Array("\(key)=\(value)".utf8)
        bytes += uint32LE(comment.count)
        bytes += comment
    }
    return bytes
}

private func metadataBlock(type: UInt8, payload: [UInt8], isLast: Bool) -> [UInt8] {
    let header = (isLast ? 0x80 : 0x00) | type
    return [header, UInt8((payload.count >> 16) & 0xff), UInt8((payload.count >> 8) & 0xff), UInt8(payload.count & 0xff)] + payload
}

private func flacPictureBlock(mimeType: String, image: [UInt8]) -> [UInt8] {
    let mime = Array(mimeType.utf8)
    return uint32BE(3)
        + uint32BE(mime.count) + mime
        + uint32BE(0)
        + uint32BE(600)
        + uint32BE(600)
        + uint32BE(24)
        + uint32BE(0)
        + uint32BE(image.count) + image
}

private func jpegBytes() -> [UInt8] {
    [0xff, 0xd8, 0xff, 0xe0, 0x00, 0x10] + Array("JFIF".utf8) + [0x00, 0xff, 0xd9]
}

private func atom(_ type: String, _ payload: [UInt8]) -> [UInt8] {
    atom(Array(type.utf8), payload)
}

private func atom(_ type: [UInt8], _ payload: [UInt8]) -> [UInt8] {
    uint32BE(payload.count + 8) + type + payload
}

private func dataAtom(_ value: String) -> [UInt8] {
    atom("data", uint32BE(1) + [0, 0, 0, 0] + Array(value.utf8))
}

private func uint24BE(_ value: Int) -> [UInt8] {
    [UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
}

private func uint32BE(_ value: Int) -> [UInt8] {
    [
        UInt8((value >> 24) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8(value & 0xff)
    ]
}

private func uint32LE(_ value: Int) -> [UInt8] {
    [
        UInt8(value & 0xff),
        UInt8((value >> 8) & 0xff),
        UInt8((value >> 16) & 0xff),
        UInt8((value >> 24) & 0xff)
    ]
}

private func uint64BE(_ value: Int64) -> [UInt8] {
    let u = UInt64(bitPattern: value)
    return (0..<8).map { UInt8((u >> (56 - $0 * 8)) & 0xff) }
}
