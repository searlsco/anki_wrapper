import Foundation

/// Just enough protobuf to read the handful of fields Anki keeps in blobs:
/// walks a message's fields, keeping the last value seen for each number
/// as the protobuf spec asks. Only the fields a caller names are kept, so a
/// hostile blob of millions of distinct fields costs no memory to walk.
struct ProtobufMessage {
  private var varints: [Int: UInt64] = [:]
  private var bytes: [Int: Data] = [:]

  init?(_ data: Data, keeping fields: Set<Int>) {
    var cursor = data.startIndex
    while cursor < data.endIndex {
      guard let key = Self.varint(in: data, at: &cursor) else { return nil }
      let field = Int(key >> 3)
      switch key & 0x7 {
      case 0:
        guard let value = Self.varint(in: data, at: &cursor) else { return nil }
        if fields.contains(field) { varints[field] = value }
      case 1:
        cursor += 8
      case 2:
        guard let length = Self.varint(in: data, at: &cursor),
          length <= UInt64(data.endIndex - cursor)
        else { return nil }
        if fields.contains(field) { bytes[field] = data[cursor..<cursor + Int(length)] }
        cursor += Int(length)
      case 5:
        cursor += 4
      default:
        return nil
      }
      guard cursor <= data.endIndex else { return nil }
    }
  }

  func varint(_ field: Int) -> UInt64 {
    varints[field] ?? 0
  }

  func string(_ field: Int) -> String {
    bytes[field].map { String(decoding: $0, as: UTF8.self) } ?? ""
  }

  func has(_ field: Int) -> Bool {
    varints[field] != nil || bytes[field] != nil
  }

  private static func varint(in data: Data, at cursor: inout Data.Index) -> UInt64? {
    var result: UInt64 = 0
    var shift: UInt64 = 0
    while cursor < data.endIndex, shift < 64 {
      let byte = data[cursor]
      cursor += 1
      result |= UInt64(byte & 0x7F) << shift
      if byte & 0x80 == 0 { return result }
      shift += 7
    }
    return nil
  }
}
