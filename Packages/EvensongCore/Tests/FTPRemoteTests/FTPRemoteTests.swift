import EvensongDomain
import FTPRemote
import Testing

@Test func ftpUnixListParserKeepsNamesWithSpaces() {
    let text = """
    drwxr-xr-x  4 owner group     4096 Jun 28 16:30 Album Folder
    -rw-r--r--  1 owner group 12345678 Jun 28 16:31 01 First Song.flac
    lrwxrwxrwx  1 owner group       11 Jun 28 16:32 Link Name -> Target Name
    """

    let entries = FTPListParser.parse(text, directory: RemotePath(displayPath: "Music"))

    #expect(entries.map(\.name) == ["Album Folder", "01 First Song.flac", "Link Name"])
    #expect(entries[0].kind == .directory)
    #expect(entries[1].kind == .file)
    #expect(entries[1].size == 12_345_678)
    #expect(entries[2].kind == .symbolicLink)
}

@Test func ftpDOSListParserReadsDirectoriesAndFiles() {
    let text = """
    06-28-26  04:30PM       <DIR>          Album Folder
    06-28-26  04:31PM             12345678 02 Second Song.mp3
    """

    let entries = FTPListParser.parse(text, directory: RemotePath(displayPath: "/Music"))

    #expect(entries.map(\.name) == ["Album Folder", "02 Second Song.mp3"])
    #expect(entries[0].kind == .directory)
    #expect(entries[1].kind == .file)
    #expect(entries[1].size == 12_345_678)
}
