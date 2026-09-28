import Foundation
import libzstd

/// Streaming zstd decompression, file to file, so a large collection never
/// sits in memory whole.
enum Zstd {
  static func decompress(_ source: URL, to destination: URL, name: String)
    throws(AnkiPackageError)
  {
    guard let input = try? FileHandle(forReadingFrom: source),
      FileManager.default.createFile(atPath: destination.path, contents: nil),
      let output = try? FileHandle(forWritingTo: destination)
    else { throw .unreadable("cannot decompress \(name)") }
    defer {
      try? input.close()
      try? output.close()
    }
    guard let stream = ZSTD_createDStream() else { throw .corruptEntry(name) }
    defer { ZSTD_freeDStream(stream) }

    var outputBuffer = [UInt8](repeating: 0, count: ZSTD_DStreamOutSize())
    var lastResult = 0
    var sawInput = false
    while let chunk = try? input.read(upToCount: ZSTD_DStreamInSize()), !chunk.isEmpty {
      sawInput = true
      let input = [UInt8](chunk)
      var position = 0
      // A full output buffer can mean more is pending, so keep draining
      // until a call leaves room even after the input is consumed.
      var produced = 0
      repeat {
        produced = input.withUnsafeBytes { raw in
          outputBuffer.withUnsafeMutableBytes { out in
            var inBuffer = ZSTD_inBuffer(src: raw.baseAddress, size: raw.count, pos: position)
            var outBuffer = ZSTD_outBuffer(dst: out.baseAddress, size: out.count, pos: 0)
            lastResult = ZSTD_decompressStream(stream, &outBuffer, &inBuffer)
            position = inBuffer.pos
            return outBuffer.pos
          }
        }
        guard ZSTD_isError(lastResult) == 0 else { throw .corruptEntry(name) }
        guard (try? output.write(contentsOf: outputBuffer[0..<produced])) != nil else {
          throw .unreadable("cannot write \(name)")
        }
      } while position < input.count || produced == outputBuffer.count
    }
    // A non-zero result means the last frame never finished: a truncated file.
    guard sawInput, lastResult == 0 else { throw .corruptEntry(name) }
  }
}
