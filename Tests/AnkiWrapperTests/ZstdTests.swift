import Foundation
import Testing
import libzstd

@testable import AnkiWrapper

@Suite struct ZstdTests {
  /// Output that ends exactly on the stream buffer's boundary, where one
  /// drain too many would start reading a frame that isn't there.
  @Test(arguments: [1, 2, 3])
  func decompressesOutputEndingOnABufferBoundary(buffers: Int) throws {
    let original = Data(
      (0..<(buffers * ZSTD_DStreamOutSize())).map { UInt8(truncatingIfNeeded: $0 * 31) })
    let source = try write(compress(original))
    let destination = scratch()

    try Zstd.decompress(source, to: destination, name: "test", limit: .max)

    #expect(try Data(contentsOf: destination) == original)
  }

  @Test func rejectsATruncatedFrame() throws {
    let compressed = compress(Data(repeating: 7, count: 500_000))
    let source = try write(compressed.prefix(compressed.count / 2))

    #expect(throws: AnkiPackageError.corruptEntry("test")) {
      try Zstd.decompress(source, to: scratch(), name: "test", limit: .max)
    }
  }

  @Test func stopsAtTheLimit() throws {
    let source = try write(compress(Data(repeating: 0, count: 1_000_000)))

    #expect(throws: AnkiPackageError.tooLarge("test")) {
      try Zstd.decompress(source, to: scratch(), name: "test", limit: 200_000)
    }
  }

  private func compress(_ data: Data) -> Data {
    var output = Data(count: ZSTD_compressBound(data.count))
    let size = output.withUnsafeMutableBytes { out in
      data.withUnsafeBytes { input in
        ZSTD_compress(out.baseAddress, out.count, input.baseAddress, input.count, 3)
      }
    }
    return output.prefix(size)
  }

  private func write(_ data: Data) throws -> URL {
    let url = scratch()
    try data.write(to: url)
    return url
  }

  private func scratch() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("ZstdTests-\(UUID().uuidString)")
  }
}
