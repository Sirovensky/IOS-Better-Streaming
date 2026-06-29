import Foundation

class ByteReader {
  private let data: Data
  private(set) var offset: Data.Index

  var availableBytes: Int {
    return data.count - offset
  }

  init(_ data: Data) {
    self.data = data
    offset = data.startIndex
  }

  func read<T>() -> T {
    let size = MemoryLayout<T>.size
    // Bounds-check: a truncated / misframed SMB response must never trap on an
    // out-of-range Data slice (EXC_BREAKPOINT). On underflow, park at the end and
    // return a zeroed value; the higher SMBRemoteClient layer then sees a bad
    // response and reconnects instead of the whole app crashing.
    guard size >= 0, offset >= data.startIndex, offset + size <= data.endIndex else {
      offset = data.endIndex
      return Data(count: max(size, 0)).to(type: T.self)
    }
    let value = data[offset..<(offset + size)].to(type: T.self)
    offset += size
    return value
  }

  func read(count: Int) -> Data {
    guard count > 0 else { return Data() }
    // Underflow → return zero-PADDED data of the requested size (never a short
    // slice, so callers doing `.to(type:)` on the result stay safe), and park at
    // the end, rather than trapping on an out-of-range slice.
    guard offset >= data.startIndex, offset + count <= data.endIndex else {
      offset = data.endIndex
      return Data(count: count)
    }
    let value = data[offset..<(offset + count)]
    offset += count
    return Data(value)
  }

  func read(from: Int, count: Int) -> Data {
    seek(to: data.startIndex + from)
    return read(count: count)
  }

  func seek(to: Int) {
    offset = data.startIndex + to
  }

  func remaining() -> Data {
    guard offset >= data.startIndex, offset < data.endIndex else { return Data() }
    return Data(data[offset...])
  }
}

extension ByteReader {
  func read() -> Bool {
    let value: UInt8 = read()
    return value == 1
  }

  func read() -> UUID {
    read(count: 16).to(type: UUID.self)
  }
}
