import Foundation

/// Picks the collection database out of a package, decompresses it into a
/// scratch directory, and hands it to `CollectionReader`.
enum PackageReader {
  static func read(_ url: URL) throws(AnkiPackageError) -> AnkiCollection {
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
      let compressed = scratch.appendingPathComponent("collection.zst")
      try archive.extract(entry, to: compressed)
      try Zstd.decompress(compressed, to: database, name: entry.name)
    } else {
      try archive.extract(entry, to: database)
    }
    return try CollectionReader.read(SQLiteDatabase(url: database), format: format)
  }

  /// Anki writes an old-format `collection.anki2` beside the real database
  /// so older versions show a "please update" note instead of failing, so
  /// the newest layout present always wins.
  private static func collectionEntry(in archive: ZipArchive)
    throws(AnkiPackageError) -> (AnkiPackageFormat, ZipArchive.Entry)
  {
    if let meta = archive.entries["meta"] {
      let data = try archive.data(for: meta)
      guard let message = ProtobufMessage(data) else { throw .corruptEntry("meta") }
      let version = Int(message.varint(1))
      switch version {
      case 1, 2:
        break
      case 3:
        guard let entry = archive.entries["collection.anki21b"] else { throw .missingCollection }
        return (.latest, entry)
      default:
        throw .unsupportedVersion(version)
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
