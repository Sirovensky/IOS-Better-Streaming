@testable import SFTPRemote
import BetterStreamingDomain
import Testing

@Test func sftpPermissionBitsMapToRemoteEntryKinds() {
    #expect(SFTPAttributeMapper.kind(fromPermissions: 0o040755) == .directory)
    #expect(SFTPAttributeMapper.kind(fromPermissions: 0o100644) == .file)
    #expect(SFTPAttributeMapper.kind(fromPermissions: 0o120777) == .symbolicLink)
    #expect(SFTPAttributeMapper.kind(fromPermissions: nil) == .file)
}

@Test func sftpSizeMapperProtectsInt64Boundary() {
    #expect(SFTPAttributeMapper.int64Size(12_345) == 12_345)
    #expect(SFTPAttributeMapper.int64Size(UInt64(Int64.max) + 1) == nil)
}
