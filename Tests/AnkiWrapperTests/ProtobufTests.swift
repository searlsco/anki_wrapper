import Foundation
import Testing

@testable import AnkiWrapper

@Suite struct ProtobufTests {
  // Field 1 varint 3, field 2 "hi", field 9 varint 7.
  let message = Data([0x08, 0x03, 0x12, 0x02, 0x68, 0x69, 0x48, 0x07])

  @Test func keepsOnlyTheFieldsAsked() throws {
    let decoded = try #require(ProtobufMessage(message, keeping: [1, 2]))

    #expect(decoded.varint(1) == 3)
    #expect(decoded.string(2) == "hi")
    #expect(!decoded.has(9))
  }

  @Test func stillRejectsATruncatedMessage() {
    #expect(ProtobufMessage(message.dropLast(), keeping: [1]) == nil)
  }
}
