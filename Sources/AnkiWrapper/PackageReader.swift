import Foundation

/// Picks the collection database out of a package, decompresses it into a
/// scratch directory, and hands it to `CollectionReader`.
enum PackageReader {
  /// `meta` is a one-field protobuf, a few bytes in every real package.
  private static let maximumMetaSize: Int64 = 1 << 16

  static func read(_ url: URL, maximumDatabaseSize: Int64) throws(AnkiPackageError)
    -> AnkiCollection
  {
    let archive = try ZipArchive(url: url)
    defer { archive.close() }
    let (format, entry) = try collectionEntry(in: archive)

    let scratch = FileManager.default.temporaryDirectory
      .appendingPathComponent("AnkiWrapper-\(UUID().uuidString)", isDirectory: true)
    do {
      try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    } catch {
      throw .unreadable(error.localizedDescription)
    }
    defer { try? FileManager.default.removeItem(at: scratch) }

    let database = scratch.appendingPathComponent("collection.sqlite")
    if format == .latest {
      // Real collections compress well, so the database's cap is ample for
      // the compressed entry too.
      let compressed = scratch.appendingPathComponent("collection.zst")
      try archive.extract(entry, to: compressed, limit: maximumDatabaseSize)
      try Zstd.decompress(
        compressed, to: database, name: entry.name, limit: maximumDatabaseSize)
      try? FileManager.default.removeItem(at: compressed)
    } else {
      try archive.extract(entry, to: database, limit: maximumDatabaseSize)
    }
    return try CollectionReader.read(
      SQLiteDatabase(url: database), format: format, maximumSize: maximumDatabaseSize)
  }

  /// Anki writes an old-format `collection.anki2` beside the real database
  /// so older versions show a "please update" note instead of failing, so
  /// the newest layout present always wins.
  private static func collectionEntry(in archive: ZipArchive)
    throws(AnkiPackageError) -> (AnkiPackageFormat, ZipArchive.Entry)
  {
    if let meta = archive.entries["meta"] {
      let data = try archive.data(for: meta, limit: maximumMetaSize)
      guard let message = ProtobufMessage(data) else { throw .corruptEntry("meta") }
      switch message.varint(1) {
      case 0:
        throw .corruptEntry("meta")
      case 1, 2:
        break
      case 3:
        guard let entry = archive.entries["collection.anki21b"] else { throw .missingCollection }
        return (.latest, entry)
      case let version:
        throw .unsupportedVersion(Int(clamping: version))
      }
    }
    if let entry = archive.entries["collection.anki21"] {
      return (.legacy2, entry)
    }
    if let entry = archive.entries["collection.anki2"] {
      return (.legacy1, entry)
    }
    throw .missingCollection
  }
}
