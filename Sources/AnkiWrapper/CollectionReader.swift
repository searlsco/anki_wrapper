import Foundation

/// Copies a collection database into values. Decks and notetypes live in
/// their own tables (with protobuf blobs) from schema 15 on, and as JSON in
/// the `col` row before that; notes, cards and the review log have kept
/// the same columns throughout.
enum CollectionReader {
  private static let sharedTables = ["col", "notes", "cards", "revlog"]
  /// Collection settings and a card's scheduling data run to a few
  /// hundred bytes; past these they are ignored rather than decoded, since
  /// decoding JSON costs far more memory than the JSON itself.
  private static let maximumSettingsSize = 1 << 16
  private static let maximumCardDataSize = 1 << 12
  private static let jsonDecodingCost: Int64 = 32
  /// A field or template row grouped under its notetype can start a
  /// dictionary entry and an array of its own: measured at about 120
  /// bytes beyond its strings.
  private static let groupedRowCost: Int64 = 128
  private static let modernTables = ["decks", "notetypes", "fields", "templates", "config"]

  static func read(
    _ database: SQLiteDatabase, format: AnkiPackageFormat, maximumSize: Int64
  ) throws(AnkiPackageError) -> AnkiCollection {
    let isModern = try database.isPlainTable("notetypes")
    for name in sharedTables + (isModern ? modernTables : [])
    where try !database.isPlainTable(name) {
      throw .database("\(name) is not a table")
    }
    let budget = Budget(remaining: maximumSize)

    let (createdAt, legacySchedulerVersion) = try collectionRow(database)
    let (decks, notetypes) =
      isModern
      ? (try modernDecks(database, budget), try modernNotetypes(database, budget))
      : try legacyDecksAndNotetypes(database, budget)
    let schedulerVersion =
      isModern ? try modernSchedulerVersion(database) : legacySchedulerVersion ?? 1
    return AnkiCollection(
      format: format, createdAt: createdAt, decks: decks, notetypes: notetypes,
      notes: try notes(database, budget), cards: try cards(database, budget),
      reviews: try reviews(database, budget, fromV1Scheduler: schedulerVersion < 2))
  }

  /// What reading may hold in memory. A database under the size cap can
  /// still expand past it (a field of a hundred million separators becomes
  /// a hundred million strings), so every row and string is charged before
  /// it is built.
  private final class Budget {
    private static let stringOverhead: Int64 = 32
    var remaining: Int64

    init(remaining: Int64) {
      self.remaining = remaining
    }

    func charge(_ bytes: Int64) throws(AnkiPackageError) {
      remaining -= bytes
      guard remaining >= 0 else { throw .tooLarge("collection") }
    }

    func string(_ text: String) throws(AnkiPackageError) -> String {
      try charge(Int64(text.utf8.count) + Self.stringOverhead)
      return text
    }

    /// Charges for copying these columns out of the row, before any is
    /// copied: a value's copy is memory too, whatever becomes of it after.
    func copying(_ columns: Int32..., of row: SQLiteDatabase.Row) throws(AnkiPackageError) {
      for column in columns { try charge(Int64(row.byteCount(column))) }
    }

    /// A legacy deck name split at Anki's `::`, charged for every piece
    /// before any is made (each colon bounds at most one piece).
    func deckPath(_ name: String) throws(AnkiPackageError) -> [String] {
      let pieces = Int64(name.utf8.count { $0 == UInt8(ascii: ":") }) + 1
      try charge(Int64(name.utf8.count) + pieces * Self.stringOverhead)
      return name.components(separatedBy: "::")
    }

    /// `text` split at `separator`, charged for every piece before any is
    /// made.
    func split(_ text: String, at separator: Character, omittingEmpty: Bool = false)
      throws(AnkiPackageError) -> [String]
    {
      let byte = separator.asciiValue ?? 0
      let pieces = Int64(text.utf8.count { $0 == byte }) + 1
      try charge(Int64(text.utf8.count) + pieces * Self.stringOverhead)
      // One pass into an array reserved up front: `split` would build a
      // second array of every piece first, at over twice the charge.
      var result: [String] = []
      result.reserveCapacity(Int(pieces))
      var start = text.startIndex
      while let end = text[start...].firstIndex(of: separator) {
        if !(omittingEmpty && start == end) { result.append(String(text[start..<end])) }
        start = text.index(after: end)
      }
      if !(omittingEmpty && start == text.endIndex) { result.append(String(text[start...])) }
      return result
    }
  }

  /// Charges for a table's rows before any is read and reserves room for
  /// them all, so the array never regrows (which briefly holds both the old
  /// buffer and one twice its size) past what was charged.
  private static func reserve<Element>(
    _ array: inout [Element], for table: String, in database: SQLiteDatabase, _ budget: Budget
  ) throws(AnkiPackageError) {
    var count: Int64 = 0
    // The table's own b-tree, which the rows are read from: an index the
    // file supplies could count anything.
    try database.query("SELECT COUNT(*) FROM \(table) NOT INDEXED") { row in count = row.int(0) }
    let (cost, overflowed) = count.multipliedReportingOverflow(
      by: Int64(MemoryLayout<Element>.stride))
    guard !overflowed, count >= 0 else { throw .tooLarge(table) }
    try budget.charge(cost)
    array.reserveCapacity(Int(count))
  }

  /// The collection's creation time and, for a legacy collection, the
  /// scheduler version its settings record. SQLite reads the one key out
  /// of the settings JSON itself, however large the rest of it is.
  private static func collectionRow(_ database: SQLiteDatabase)
    throws(AnkiPackageError) -> (Date, Int?)
  {
    var created: Int64 = 0
    var schedulerVersion: Int?
    try database.query(
      """
      SELECT crt, CASE WHEN json_valid(conf) THEN json_extract(conf, '$.schedVer') END
      FROM col
      """
    ) { row throws(AnkiPackageError) in
      created = row.int(0)
      schedulerVersion = row.isNull(1) ? nil : Int(row.int(1))
    }
    return (Date(timeIntervalSince1970: Double(created)), schedulerVersion)
  }

  /// Anki treats a collection that never recorded a scheduler version as
  /// the original v1 scheduler.
  private static func modernSchedulerVersion(_ database: SQLiteDatabase)
    throws(AnkiPackageError) -> Int
  {
    var version = 1
    try database.query(
      """
      SELECT CASE WHEN length(CAST(val AS BLOB)) <= \(maximumSettingsSize) THEN val END
      FROM config WHERE KEY = 'schedVer'
      """
    ) {
      row throws(AnkiPackageError) in
      let value = row.data(0)
      guard value.count <= maximumSettingsSize else { return }
      version = (try? JSONDecoder().decode(Int.self, from: value)) ?? version
    }
    return version
  }

  private static func modernDecks(_ database: SQLiteDatabase, _ budget: Budget)
    throws(AnkiPackageError) -> [AnkiDeck]
  {
    var decks: [AnkiDeck] = []
    try reserve(&decks, for: "decks", in: database, budget)
    try database.query("SELECT id, name, kind FROM decks ORDER BY rowid") {
      row throws(AnkiPackageError) in
      // `kind` holds a oneof: 1 is a normal deck, 2 a filtered one.
      try budget.copying(1, 2, of: row)
      let kind = ProtobufMessage(row.data(2), keeping: [1, 2])
      decks.append(
        AnkiDeck(
          id: row.int(0), path: try budget.split(row.string(1), at: "\u{1f}"),
          isFiltered: kind?.has(2) ?? false))
    }
    return decks
  }

  private static func modernNotetypes(_ database: SQLiteDatabase, _ budget: Budget)
    throws(AnkiPackageError) -> [AnkiNotetype]
  {
    // Rows come in whatever order the file keeps them and are sorted here:
    // an ORDER BY over columns a hostile file declared could make SQLite
    // hold every key in memory the budget never sees.
    var fieldRows: [Int64: [(ord: Int64, name: String)]] = [:]
    try database.query("SELECT ntid, ord, name FROM fields") {
      row throws(AnkiPackageError) in
      try budget.charge(groupedRowCost)
      try budget.copying(2, of: row)
      fieldRows[row.int(0), default: []].append((row.int(1), try budget.string(row.string(2))))
    }
    let fields = fieldRows.mapValues { $0.sorted { $0.ord < $1.ord }.map(\.name) }
    var templateRows: [Int64: [(ord: Int64, template: AnkiTemplate)]] = [:]
    try database.query("SELECT ntid, ord, name, config FROM templates") {
      row throws(AnkiPackageError) in
      try budget.charge(groupedRowCost)
      try budget.copying(2, 3, of: row)
      let config = ProtobufMessage(row.data(3), keeping: [1, 2])
      templateRows[row.int(0), default: []].append(
        (
          row.int(1),
          AnkiTemplate(
            name: try budget.string(row.string(2)),
            questionFormat: try budget.string(config?.string(1) ?? ""),
            answerFormat: try budget.string(config?.string(2) ?? ""))
        ))
    }
    let templates = templateRows.mapValues { $0.sorted { $0.ord < $1.ord }.map(\.template) }
    var notetypes: [AnkiNotetype] = []
    try reserve(&notetypes, for: "notetypes", in: database, budget)
    try database.query("SELECT id, name, config FROM notetypes ORDER BY rowid") {
      row throws(AnkiPackageError) in
      let id = row.int(0)
      try budget.copying(1, 2, of: row)
      let isCloze = ProtobufMessage(row.data(2), keeping: [1])?.varint(1) == 1
      notetypes.append(
        AnkiNotetype(
          id: id, name: try budget.string(row.string(1)), kind: isCloze ? .cloze : .standard,
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

  private static func legacyDecksAndNotetypes(_ database: SQLiteDatabase, _ budget: Budget)
    throws(AnkiPackageError) -> ([AnkiDeck], [AnkiNotetype])
  {
    var decksJson = ""
    var modelsJson = ""
    try database.query("SELECT decks, models FROM col") { row throws(AnkiPackageError) in
      try budget.copying(0, 1, of: row)
      decksJson = try budget.string(row.string(0))
      modelsJson = try budget.string(row.string(1))
      // JSONDecoder indexes the whole document first, which measures at
      // tens of times the JSON's own size.
      try budget.charge(jsonDecodingCost * Int64(decksJson.utf8.count + modelsJson.utf8.count))
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
    try budget.charge(
      Int64(
        legacyDecks.count * MemoryLayout<AnkiDeck>.stride
          + legacyModels.count * MemoryLayout<AnkiNotetype>.stride))
    var decks: [AnkiDeck] = []
    for (key, deck) in legacyDecks {
      guard let id = Int64(key) else { continue }
      decks.append(
        AnkiDeck(id: id, path: try budget.deckPath(deck.name), isFiltered: deck.dyn == 1))
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

  private static func notes(_ database: SQLiteDatabase, _ budget: Budget)
    throws(AnkiPackageError) -> [AnkiNote]
  {
    var notes: [AnkiNote] = []
    try reserve(&notes, for: "notes", in: database, budget)
    try database.query("SELECT id, guid, mid, mod, tags, flds FROM notes ORDER BY rowid") {
      row throws(AnkiPackageError) in
      try budget.copying(1, 4, 5, of: row)
      notes.append(
        AnkiNote(
          id: row.int(0), guid: try budget.string(row.string(1)), notetypeId: row.int(2),
          modifiedAt: Date(timeIntervalSince1970: Double(row.int(3))),
          tags: try budget.split(row.string(4), at: " ", omittingEmpty: true),
          fields: try budget.split(row.string(5), at: "\u{1f}")))
    }
    return notes
  }

  private static func cards(_ database: SQLiteDatabase, _ budget: Budget)
    throws(AnkiPackageError) -> [AnkiCard]
  {
    var cards: [AnkiCard] = []
    try reserve(&cards, for: "cards", in: database, budget)
    try database.query(
      """
      SELECT id, nid, did, odid, ord, type, queue, due, ivl, factor, reps, lapses, odue,
        CASE WHEN length(CAST(data AS BLOB)) <= \(maximumCardDataSize) THEN data END
      FROM cards ORDER BY rowid
      """
    ) { row throws(AnkiPackageError) in
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
    guard json.hasPrefix("{"), json.utf8.count <= maximumCardDataSize,
      let data = try? JSONDecoder().decode(CardData.self, from: Data(json.utf8)),
      let stability = data.s, let difficulty = data.d
    else { return nil }
    return AnkiCard.MemoryState(stability: stability, difficulty: difficulty)
  }

  /// The v1 scheduler gave learning and relearning cards three buttons, so
  /// its 2 and 3 there meant Good and Easy. Anki shifts them the same way
  /// when it upgrades such a collection.
  private static func reviews(
    _ database: SQLiteDatabase, _ budget: Budget, fromV1Scheduler: Bool
  ) throws(AnkiPackageError) -> [AnkiReview] {
    var reviews: [AnkiReview] = []
    try reserve(&reviews, for: "revlog", in: database, budget)
    try database.query(
      "SELECT id, cid, ease, ivl, lastIvl, factor, time, type FROM revlog ORDER BY rowid"
    ) { row throws(AnkiPackageError) in
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
