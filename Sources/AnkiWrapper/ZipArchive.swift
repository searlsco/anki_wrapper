import Compression
import Foundation
import zlib

/// Reads entries out of a ZIP archive through its central directory,
/// seeking to each one, so a collection with gigabytes of media costs only
/// the entries asked for. Handles what Anki writes: Stored and Deflate
/// entries, with ZIP64 records once an archive passes 4 GB.
struct ZipArchive {
  struct Entry {
    let name: String
    let method: UInt16
    let flags: UInt16
    let crc32: UInt32
    let compressedSize: UInt64
    let uncompressedSize: UInt64
    let localHeaderOffset: UInt64
  }

  private static let stored: UInt16 = 0
  private static let deflated: UInt16 = 8
  private static let chunkSize = 1 << 20

  private let handle: FileHandle
  private let fileSize: UInt64
  let entries: [String: Entry]

  init(url: URL) throws(AnkiPackageError) {
    do {
      handle = try FileHandle(forReadingFrom: url)
      fileSize = try handle.seekToEnd()
    } catch {
      throw .unreadable(error.localizedDescription)
    }
    let directory = try Self.centralDirectory(handle: handle, fileSize: fileSize)
    entries = try Self.parseEntries(directory.bytes, count: directory.count)
  }

  func close() {
    try? handle.close()
  }

  /// The whole entry in memory, for the small ones (`meta`).
  func data(for entry: Entry, limit: Int64) throws(AnkiPackageError) -> Data {
    try refuse(entry, over: limit)
    var result = Data()
    try stream(entry) { result.append($0) }
    return result
  }

  /// Streams the entry to a new file at `destination`.
  func extract(_ entry: Entry, to destination: URL, limit: Int64) throws(AnkiPackageError) {
    try refuse(entry, over: limit)
    guard FileManager.default.createFile(atPath: destination.path, contents: nil),
      let output = try? FileHandle(forWritingTo: destination)
    else { throw .unreadable("cannot write \(destination.lastPathComponent)") }
    defer { try? output.close() }
    var writeError: (any Error)?
    try stream(entry) { chunk in
      guard writeError == nil else { return }
      do { try output.write(contentsOf: chunk) } catch { writeError = error }
    }
    if let writeError { throw .unreadable(writeError.localizedDescription) }
  }

  /// Streaming stops the moment an entry outgrows its declared size, so
  /// capping the declared size caps what any entry can produce.
  private func refuse(_ entry: Entry, over limit: Int64) throws(AnkiPackageError) {
    guard entry.uncompressedSize <= UInt64(max(0, limit)) else { throw .tooLarge(entry.name) }
  }

  private func stream(_ entry: Entry, into sink: @escaping (Data) -> Void) throws(AnkiPackageError)
  {
    guard entry.flags & 1 == 0 else { throw .unsupportedEntry("\(entry.name) is encrypted") }
    guard entry.method == Self.stored || entry.method == Self.deflated else {
      throw .unsupportedEntry("\(entry.name) uses compression method \(entry.method)")
    }
    let local = try read(at: entry.localHeaderOffset, count: 30)
    guard local.uint32(at: 0) == 0x0403_4b50 else { throw .corruptEntry(entry.name) }
    var offset =
      entry.localHeaderOffset + 30 + UInt64(local.uint16(at: 26)) + UInt64(local.uint16(at: 28))

    var checksum = CRC32()
    var produced: UInt64 = 0
    let emit: (Data) throws(AnkiPackageError) -> Void = { chunk throws(AnkiPackageError) in
      produced += UInt64(chunk.count)
      guard produced <= entry.uncompressedSize else {
        throw AnkiPackageError.corruptEntry(entry.name)
      }
      checksum.update(chunk)
      sink(chunk)
    }

    var remaining = entry.compressedSize
    if entry.method == Self.stored {
      while remaining > 0 {
        let count = Int(min(UInt64(Self.chunkSize), remaining))
        try emit(try read(at: offset, count: count))
        offset += UInt64(count)
        remaining -= UInt64(count)
      }
    } else {
      do {
        let filter = try OutputFilter(.decompress, using: .zlib) { try emit($0 ?? Data()) }
        while remaining > 0 {
          let count = Int(min(UInt64(Self.chunkSize), remaining))
          try filter.write(try read(at: offset, count: count))
          offset += UInt64(count)
          remaining -= UInt64(count)
        }
        try filter.finalize()
      } catch let error as AnkiPackageError {
        throw error
      } catch {
        throw .corruptEntry(entry.name)
      }
    }
    guard produced == entry.uncompressedSize, checksum.value == entry.crc32 else {
      throw .corruptEntry(entry.name)
    }
  }

  private func read(at offset: UInt64, count: Int) throws(AnkiPackageError) -> Data {
    guard let data = Self.read(handle: handle, at: offset, count: count) else {
      throw .unreadable("the archive ends early")
    }
    return data
  }

  private static func read(handle: FileHandle, at offset: UInt64, count: Int) -> Data? {
    guard count > 0 else { return Data() }
    guard (try? handle.seek(toOffset: offset)) != nil,
      let data = try? handle.read(upToCount: count), data.count == count
    else { return nil }
    return data
  }

  private static func centralDirectory(handle: FileHandle, fileSize: UInt64)
    throws(AnkiPackageError) -> (bytes: Data, count: UInt64)
  {
    // The end record is 22 bytes plus a comment of at most 65,535.
    let tailLength = Int(min(fileSize, 22 + 65_535))
    guard tailLength >= 22,
      let tail = read(handle: handle, at: fileSize - UInt64(tailLength), count: tailLength),
      let endIndex = tail.lastIndex(ofSignature: 0x0605_4b50, from: tailLength - 22)
    else { throw .notAPackage }

    var count = UInt64(tail.uint16(at: endIndex + 10))
    var size = UInt64(tail.uint32(at: endIndex + 12))
    var start = UInt64(tail.uint32(at: endIndex + 16))
    let endOffset = fileSize - UInt64(tailLength) + UInt64(endIndex)
    if count == 0xFFFF || size == 0xFFFF_FFFF || start == 0xFFFF_FFFF, endOffset >= 20,
      let locator = read(handle: handle, at: endOffset - 20, count: 20),
      locator.uint32(at: 0) == 0x0706_4b50,
      let record = read(handle: handle, at: locator.uint64(at: 8), count: 56),
      record.uint32(at: 0) == 0x0606_4b50
    {
      count = record.uint64(at: 32)
      size = record.uint64(at: 40)
      start = record.uint64(at: 48)
    }
    guard size <= fileSize, start <= fileSize - size,
      let bytes = read(handle: handle, at: start, count: Int(size))
    else { throw .notAPackage }
    return (bytes, count)
  }

  private static func parseEntries(_ bytes: Data, count: UInt64)
    throws(AnkiPackageError) -> [String: Entry]
  {
    var entries: [String: Entry] = [:]
    var cursor = 0
    for _ in 0..<count {
      guard cursor + 46 <= bytes.count, bytes.uint32(at: cursor) == 0x0201_4b50 else {
        throw .notAPackage
      }
      let nameLength = Int(bytes.uint16(at: cursor + 28))
      let extraLength = Int(bytes.uint16(at: cursor + 30))
      let commentLength = Int(bytes.uint16(at: cursor + 32))
      let nameStart = cursor + 46
      guard nameStart + nameLength + extraLength <= bytes.count else { throw .notAPackage }
      let name = String(
        decoding: bytes[bytes.startIndex + nameStart..<bytes.startIndex + nameStart + nameLength],
        as: UTF8.self)

      var uncompressed = UInt64(bytes.uint32(at: cursor + 24))
      var compressed = UInt64(bytes.uint32(at: cursor + 20))
      var offset = UInt64(bytes.uint32(at: cursor + 42))
      // A ZIP64 extra field carries, in this order, whichever of the three
      // values overflowed their 32-bit slots.
      var extra = nameStart + nameLength
      let extraEnd = extra + extraLength
      while extra + 4 <= extraEnd {
        let id = bytes.uint16(at: extra)
        let length = Int(bytes.uint16(at: extra + 2))
        if id == 0x0001 {
          var field = extra + 4
          if uncompressed == 0xFFFF_FFFF, field + 8 <= extraEnd {
            uncompressed = bytes.uint64(at: field)
            field += 8
          }
          if compressed == 0xFFFF_FFFF, field + 8 <= extraEnd {
            compressed = bytes.uint64(at: field)
            field += 8
          }
          if offset == 0xFFFF_FFFF, field + 8 <= extraEnd {
            offset = bytes.uint64(at: field)
          }
        }
        extra += 4 + length
      }

      entries[name] = Entry(
        name: name, method: bytes.uint16(at: cursor + 10), flags: bytes.uint16(at: cursor + 8),
        crc32: bytes.uint32(at: cursor + 16), compressedSize: compressed,
        uncompressedSize: uncompressed, localHeaderOffset: offset)
      cursor = extraEnd + commentLength
    }
    return entries
  }
}

struct CRC32 {
  private(set) var value: UInt32 = 0

  mutating func update(_ data: Data) {
    let running = uLong(value)
    value = UInt32(
      data.withUnsafeBytes { bytes in
        crc32(running, bytes.bindMemory(to: Bytef.self).baseAddress, uInt(bytes.count))
      })
  }
}

extension Data {
  func uint16(at offset: Int) -> UInt16 {
    littleEndian(at: offset, byteCount: 2)
  }

  func uint32(at offset: Int) -> UInt32 {
    littleEndian(at: offset, byteCount: 4)
  }

  func uint64(at offset: Int) -> UInt64 {
    littleEndian(at: offset, byteCount: 8)
  }

  fileprivate func lastIndex(ofSignature signature: UInt32, from start: Int) -> Int? {
    stride(from: start, through: 0, by: -1).first { uint32(at: $0) == signature }
  }

  private func littleEndian<T: FixedWidthInteger>(at offset: Int, byteCount: Int) -> T {
    var value: T = 0
    for index in 0..<byteCount {
      value |= T(self[startIndex + offset + index]) << (8 * index)
    }
    return value
  }
}
