import Foundation

/// Copies a collection database into values. Decks and notetypes live in
/// their own tables (with protobuf blobs) from schema 15 on, and as JSON in
/// the `col` row before that; notes, cards and the review log have kept
/// the same columns throughout.
enum CollectionReader {
  private static let sharedTables = ["col", "notes", "cards", "revlog"]
  private static let modernTables = ["decks", "notetypes", "fields", "templates", "config"]

  static func read(_ database: SQLiteDatabase, format: AnkiPackageFormat)
    throws(AnkiPackageError) -> AnkiCollection
  {
    let objects = try database.objectTypes()
    let isModern = objects["notetypes"] != nil
    for name in sharedTables + (isModern ? modernTables : [])
    where objects[name] != "table" {
      throw .database("\(name) is not a table")
    }

    let (createdAt, legacyConfig) = try collectionRow(database)
    let (decks, notetypes) =
      isModern
      ? (try modernDecks(database), try modernNotetypes(database))
      : try legacyDecksAndNotetypes(database)
    let schedulerVersion =
      isModern ? try modernSchedulerVersion(database) : legacyConfig?.schedVer ?? 1
    return AnkiCollection(
      format: format, createdAt: createdAt, decks: decks, notetypes: notetypes,
      notes: try notes(database), cards: try cards(database),
      reviews: try reviews(database, fromV1Scheduler: schedulerVersion < 2))
  }

  private struct LegacyConfig: Decodable {
    let schedVer: Int?
  }

  private static func collectionRow(_ database: SQLiteDatabase)
    throws(AnkiPackageError) -> (Date, LegacyConfig?)
  {
    var created: Int64 = 0
    var conf = ""
    try database.query("SELECT crt, conf FROM col") { row in
      created = row.int(0)
      conf = row.string(1)
    }
    return (
      Date(timeIntervalSince1970: Double(created)),
      try? JSONDecoder().decode(LegacyConfig.self, from: Data(conf.utf8))
    )
  }

  /// Anki treats a collection that never recorded a scheduler version as
  /// the original v1 scheduler.
  private static func modernSchedulerVersion(_ database: SQLiteDatabase)
    throws(AnkiPackageError) -> Int
  {
    var version = 1
    try database.query("SELECT val FROM config WHERE KEY = 'schedVer'") { row in
      version = (try? JSONDecoder().decode(Int.self, from: row.data(0))) ?? version
    }
    return version
  }

  private static func modernDecks(_ database: SQLiteDatabase) throws(AnkiPackageError)
    -> [AnkiDeck]
  {
    var decks: [AnkiDeck] = []
    try database.query("SELECT id, name, kind FROM decks ORDER BY id") { row in
      // `kind` holds a oneof: 1 is a normal deck, 2 a filtered one.
      let kind = ProtobufMessage(row.data(2))
      decks.append(
        AnkiDeck(
          id: row.int(0), path: row.string(1).components(separatedBy: "\u{1f}"),
          isFiltered: kind?.has(2) ?? false))
    }
    return decks
  }

  private static func modernNotetypes(_ database: SQLiteDatabase) throws(AnkiPackageError)
    -> [AnkiNotetype]
  {
    var fields: [Int64: [String]] = [:]
    try database.query("SELECT ntid, name FROM fields ORDER BY ntid, ord") { row in
      fields[row.int(0), default: []].append(row.string(1))
    }
    var templates: [Int64: [AnkiTemplate]] = [:]
    try database.query("SELECT ntid, name, config FROM templates ORDER BY ntid, ord") { row in
      let config = ProtobufMessage(row.data(2))
      templates[row.int(0), default: []].append(
        AnkiTemplate(
          name: row.string(1), questionFormat: config?.string(1) ?? "",
          answerFormat: config?.string(2) ?? ""))
    }
    var notetypes: [AnkiNotetype] = []
    try database.query("SELECT id, name, config FROM notetypes ORDER BY id") { row in
      let id = row.int(0)
      let isCloze = ProtobufMessage(row.data(2))?.varint(1) == 1
      notetypes.append(
        AnkiNotetype(
          id: id, name: row.string(1), kind: isCloze ? .cloze : .standard,
          fields: fields[id] ?? [], templates: templates[id] ?? []))
    }
    return notetypes
  }

  private struct LegacyDeck: Decodable {
    let name: String
    let dyn: Int?
  }

  private struct LegacyNotetype: Decodable {
    struct Field: Decodable {
      let name: String
      let ord: Int
    }

    struct Template: Decodable {
      let name: String
      let ord: Int
      let qfmt: String
      let afmt: String
    }

    let name: String
    let type: Int?
    let flds: [Field]
    let tmpls: [Template]
  }

  private static func legacyDecksAndNotetypes(_ database: SQLiteDatabase)
    throws(AnkiPackageError) -> ([AnkiDeck], [AnkiNotetype])
  {
    var decksJson = ""
    var modelsJson = ""
    try database.query("SELECT decks, models FROM col") { row in
      decksJson = row.string(0)
      modelsJson = row.string(1)
    }
    let decoder = JSONDecoder()
    let legacyDecks: [String: LegacyDeck]
    let legacyModels: [String: LegacyNotetype]
    do {
      legacyDecks = try decoder.decode([String: LegacyDeck].self, from: Data(decksJson.utf8))
      legacyModels = try decoder.decode(
        [String: LegacyNotetype].self, from: Data(modelsJson.utf8))
    } catch {
      throw .database("unreadable deck or notetype JSON: \(error)")
    }
    let decks = legacyDecks.compactMap { key, deck in
      Int64(key).map {
        AnkiDeck(
          id: $0, path: deck.name.components(separatedBy: "::"), isFiltered: deck.dyn == 1)
      }
    }
    let notetypes = legacyModels.compactMap { key, model in
      Int64(key).map {
        AnkiNotetype(
          id: $0, name: model.name, kind: model.type == 1 ? .cloze : .standard,
          fields: model.flds.sorted { $0.ord < $1.ord }.map(\.name),
          templates: model.tmpls.sorted { $0.ord < $1.ord }.map {
            AnkiTemplate(name: $0.name, questionFormat: $0.qfmt, answerFormat: $0.afmt)
          })
      }
    }
    return (decks.sorted { $0.id < $1.id }, notetypes.sorted { $0.id < $1.id })
  }

  private static func notes(_ database: SQLiteDatabase) throws(AnkiPackageError) -> [AnkiNote] {
    var notes: [AnkiNote] = []
    try database.query("SELECT id, guid, mid, mod, tags, flds FROM notes ORDER BY id") { row in
      notes.append(
        AnkiNote(
          id: row.int(0), guid: row.string(1), notetypeId: row.int(2),
          modifiedAt: Date(timeIntervalSince1970: Double(row.int(3))),
          tags: row.string(4).split(separator: " ").map(String.init),
          fields: row.string(5).components(separatedBy: "\u{1f}")))
    }
    return notes
  }

  private static func cards(_ database: SQLiteDatabase) throws(AnkiPackageError) -> [AnkiCard] {
    var cards: [AnkiCard] = []
    try database.query(
      """
      SELECT id, nid, did, odid, ord, type, queue, due, ivl, factor, reps, lapses, odue, data
      FROM cards ORDER BY id
      """
    ) { row in
      let deck = row.int(2)
      let home = row.int(3)
      // A filtered deck parks the card's own due in `odue` while it holds it.
      cards.append(
        AnkiCard(
          id: row.int(0), noteId: row.int(1), deckId: home == 0 ? deck : home,
          filteredDeckId: home == 0 ? nil : deck, ordinal: Int(row.int(4)),
          kind: cardKind(Int(row.int(5))), queue: queue(Int(row.int(6))),
          due: home == 0 ? row.int(7) : row.int(12), interval: row.int(8),
          easeFactor: Int(row.int(9)), reviewCount: Int(row.int(10)),
          lapseCount: Int(row.int(11)), memoryState: memoryState(row.string(13))))
    }
    return cards
  }

  private struct CardData: Decodable {
    let s: Double?
    let d: Double?
  }

  /// FSRS keeps its state in the card's `data` JSON as `s` and `d`.
  private static func memoryState(_ json: String) -> AnkiCard.MemoryState? {
    guard json.hasPrefix("{"),
      let data = try? JSONDecoder().decode(CardData.self, from: Data(json.utf8)),
      let stability = data.s, let difficulty = data.d
    else { return nil }
    return AnkiCard.MemoryState(stability: stability, difficulty: difficulty)
  }

  /// The v1 scheduler gave learning and relearning cards three buttons, so
  /// its 2 and 3 there meant Good and Easy. Anki shifts them the same way
  /// when it upgrades such a collection.
  private static func reviews(_ database: SQLiteDatabase, fromV1Scheduler: Bool)
    throws(AnkiPackageError) -> [AnkiReview]
  {
    var reviews: [AnkiReview] = []
    try database.query(
      "SELECT id, cid, ease, ivl, lastIvl, factor, time, type FROM revlog ORDER BY id"
    ) { row in
      let kind = Int(row.int(7))
      var ease = Int(row.int(2))
      if fromV1Scheduler, kind == 0 || kind == 2, ease == 2 || ease == 3 {
        ease += 1
      }
      reviews.append(
        AnkiReview(
          id: row.int(0), cardId: row.int(1), rating: AnkiReview.Rating(rawValue: ease),
          kind: reviewKind(kind), interval: row.int(3), lastInterval: row.int(4),
          easeFactor: Int(row.int(5)), duration: .milliseconds(row.int(6))))
    }
    return reviews
  }

  private static func cardKind(_ raw: Int) -> AnkiCard.Kind {
    switch raw {
    case 0: .new
    case 1: .learning
    case 2: .review
    case 3: .relearning
    default: .unknown(raw)
    }
  }

  private static func queue(_ raw: Int) -> AnkiCard.Queue {
    switch raw {
    case -3: .buriedByUser
    case -2: .buriedBySibling
    case -1: .suspended
    case 0: .new
    case 1: .learning
    case 2: .review
    case 3: .dayLearning
    case 4: .preview
    default: .unknown(raw)
    }
  }

  private static func reviewKind(_ raw: Int) -> AnkiReview.Kind {
    switch raw {
    case 0: .learning
    case 1: .review
    case 2: .relearning
    case 3: .filtered
    case 4: .manual
    case 5: .rescheduled
    default: .unknown(raw)
    }
  }
}
