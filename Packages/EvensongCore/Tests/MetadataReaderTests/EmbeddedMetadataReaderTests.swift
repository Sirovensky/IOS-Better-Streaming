import Foundation
import MetadataReader
import Testing

@Test func id3v23TextFramesAreParsed() {
    let frames = id3TextFrame("TIT2", "Track Title")
        + id3TextFrame("TPE1", "Real Artist")
        + id3TextFrame("TALB", "Real Album")
        + id3TextFrame("TCON", "(17)")
        + id3TextFrame("TRCK", "04/12")
    let data = Data(Array("ID3".utf8) + [3, 0, 0] + syncSafe(frames.count) + frames)

    let metadata = EmbeddedMetadataReader.parse(data, fileExtension: "mp3")

    #expect(metadata.title == "Track Title")
    #expect(metadata.artist == "Real Artist")
    #expect(metadata.album == "Real Album")
    #expect(metadata.genre == "Rock")
    #expect(metadata.trackNumber == 4)
}

@Test func flacVorbisCommentsAreParsed() {
    let comments = vorbisComments([
        "TITLE": "Flac Title",
        "ARTIST": "Flac Artist",
        "ALBUM": "Flac Album",
        "GENRE": "Progressive Rock",
        "TRACKNUMBER": "7"
    ])
    let data = Data(Array("fLaC".utf8) + metadataBlock(type: 4, payload: comments, isLast: true))

    let metadata = EmbeddedMetadataReader.parse(data, fileExtension: "flac")

    #expect(metadata.title == "Flac Title")
    #expect(metadata.artist == "Flac Artist")
    #expect(metadata.album == "Flac Album")
    #expect(metadata.genre == "Progressive Rock")
    #expect(metadata.trackNumber == 7)
}

@Test func mp4ITunesAtomsAreParsed() {
    let ilst = atom("ilst",
        atom([0xa9, 0x6e, 0x61, 0x6d], dataAtom("MP4 Title"))
            + atom([0xa9, 0x41, 0x52, 0x54], dataAtom("MP4 Artist"))
            + atom([0xa9, 0x61, 0x6c, 0x62], dataAtom("MP4 Album"))
            + atom([0xa9, 0x67, 0x65, 0x6e], dataAtom("Electronic"))
            + atom("trkn", binaryDataAtom([0, 0, 0, 9, 0, 12, 0, 0]))
    )
    let data = Data(atom("ftyp", Array("M4A ".utf8)) + atom("moov", atom("udta", atom("meta", [0, 0, 0, 0] + ilst))))

    let metadata = EmbeddedMetadataReader.parse(data, fileExtension: "m4a")

    #expect(metadata.title == "MP4 Title")
    #expect(metadata.artist == "MP4 Artist")
    #expect(metadata.album == "MP4 Album")
    #expect(metadata.genre == "Electronic")
    #expect(metadata.trackNumber == 9)
}

@Test func id3AttachedPictureIsParsed() {
    let image = jpegBytes()
    let payload = [UInt8(3)] + Array("image/jpeg".utf8) + [0, 3, 0] + image
    let frame = Array("APIC".utf8) + uint32BE(payload.count) + [0, 0] + payload
    let data = Data(Array("ID3".utf8) + [3, 0, 0] + syncSafe(frame.count) + frame)

    let metadata = EmbeddedMetadataReader.parse(data, fileExtension: "mp3")

    #expect(metadata.artwork?.fileExtension == "jpg")
    #expect(metadata.artwork?.mimeType == "image/jpeg")
    #expect(metadata.artwork?.data == Data(image))
}

@Test func flacPictureBlockIsParsed() {
    let image = jpegBytes()
    let picture = flacPictureBlock(mimeType: "image/jpeg", image: image)
    let data = Data(Array("fLaC".utf8) + metadataBlock(type: 6, payload: picture, isLast: true))

    let metadata = EmbeddedMetadataReader.parse(data, fileExtension: "flac")

    #expect(metadata.artwork?.fileExtension == "jpg")
    #expect(metadata.artwork?.data == Data(image))
}

/// A FLAC whose Vorbis comments + picture block fill every ID3-fillable field
/// takes the `isComplete` fast path (the secondary ID3 scan is skipped). The
/// result must still carry all fields — the skip is behaviour-preserving.
@Test func flacWithCompleteTagsAndArtworkParsesEveryField() {
    let comments = vorbisComments([
        "TITLE": "Complete Title",
        "ARTIST": "Complete Artist",
        "ALBUM": "Complete Album",
        "GENRE": "Ambient",
        "TRACKNUMBER": "3",
        "DISCNUMBER": "2"
    ])
    let image = jpegBytes()
    let picture = flacPictureBlock(mimeType: "image/jpeg", image: image)
    let data = Data(
        Array("fLaC".utf8)
            + metadataBlock(type: 4, payload: comments, isLast: false)
            + metadataBlock(type: 6, payload: picture, isLast: true)
    )

    let metadata = EmbeddedMetadataReader.parse(data, fileExtension: "flac")

    #expect(metadata.title == "Complete Title")
    #expect(metadata.artist == "Complete Artist")
    #expect(metadata.album == "Complete Album")
    #expect(metadata.genre == "Ambient")
    #expect(metadata.trackNumber == 3)
    #expect(metadata.discNumber == 2)
    #expect(metadata.artwork?.data == Data(image))
}

/// A FLAC missing some tags still runs the ID3 fallback (isComplete is false),
/// so an appended ID3 tag fills the gaps.
@Test func flacWithPartialTagsFallsBackToTrailingID3() {
    let comments = vorbisComments(["TITLE": "Vorbis Title"])
    let id3Frames = id3TextFrame("TPE1", "ID3 Artist") + id3TextFrame("TALB", "ID3 Album")
    let id3 = Array("ID3".utf8) + [3, 0, 0] + syncSafe(id3Frames.count) + id3Frames
    let data = Data(
        Array("fLaC".utf8)
            + metadataBlock(type: 4, payload: comments, isLast: true)
            + id3
    )

    let metadata = EmbeddedMetadataReader.parse(data, fileExtension: "flac")

    #expect(metadata.title == "Vorbis Title")   // primary parse wins
    #expect(metadata.artist == "ID3 Artist")    // fallback fills the gap
    #expect(metadata.album == "ID3 Album")
}

@Test func mp4CoverAtomIsParsed() {
    let image = jpegBytes()
    let ilst = atom("ilst", atom("covr", binaryDataAtom(image, type: 13)))
    let data = Data(atom("ftyp", Array("M4A ".utf8)) + atom("moov", atom("udta", atom("meta", [0, 0, 0, 0] + ilst))))

    let metadata = EmbeddedMetadataReader.parse(data, fileExtension: "m4a")

    #expect(metadata.artwork?.fileExtension == "jpg")
    #expect(metadata.artwork?.data == Data(image))
}

private func id3TextFrame(_ id: String, _ value: String) -> [UInt8] {
    let payload = [UInt8(3)] + Array(value.utf8)
    return Array(id.utf8) + uint32BE(payload.count) + [0, 0] + payload
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
    binaryDataAtom(Array(value.utf8), type: 1)
}

private func binaryDataAtom(_ payload: [UInt8], type: UInt32 = 0) -> [UInt8] {
    atom("data", uint32BE(Int(type)) + [0, 0, 0, 0] + payload)
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
