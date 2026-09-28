import AnkiWrapper
import Foundation
import Testing

// Expected values were read from each fixture independently with Python's
// sqlite3 module and the zstd command-line tool, not through this library.
@Suite struct AnkiCollectionTests {
  static let n5 = ["Open Anki JLPT N5 Deck"]
  static let sentences = ["Open Anki JLPT N5 Deck", "Sentences"]

  static func fixture(_ name: String) throws -> URL {
    try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
  }

  @Test(arguments: [
    ("collection.colpkg", AnkiPackageFormat.latest),
    ("collection-legacy.colpkg", AnkiPackageFormat.legacy2),
  ])
  func readsAWholeCollection(name: String, format: AnkiPackageFormat) throws {
    let collection = try AnkiCollection(contentsOf: Self.fixture(name))

    #expect(collection.format == format)
    #expect(collection.createdAt == Date(timeIntervalSince1970: 1_790_582_400))
    #expect(collection.notes.count == 1391)
    #expect(collection.cards.count == 2778)
    #expect(collection.reviews.count == 206)
    #expect(
      Set(collection.decks.map(\.path)) == [
        ["Default"], ["Open Anki JLPT N4 Deck"], Self.n5, Self.sentences, ["Cram"],
      ])
    #expect(collection.decks.filter(\.isFiltered).map(\.name) == ["Cram"])
    #expect(
      collection.decks.first { $0.path == Self.sentences }?.name
        == "Open Anki JLPT N5 Deck::Sentences")
  }

  @Test(arguments: ["collection.colpkg", "collection-legacy.colpkg"])
  func readsNotetypesWithFieldsAndTemplates(name: String) throws {
    let collection = try AnkiCollection(contentsOf: Self.fixture(name))

    let vocab = try #require(collection.notetypes.first { $0.name == "Open Anki JLPT Vocab" })
    #expect(vocab.id == 2_000_494_194)
    #expect(vocab.kind == .standard)
    #expect(vocab.fields == ["expression", "reading", "meaning"])
    #expect(vocab.templates.map(\.name) == ["JLPT JP to EN", "JLPT EN to JP"])
    #expect(vocab.templates[0].questionFormat.contains("{{expression}}"))
    #expect(vocab.templates[1].questionFormat.contains("{{meaning}}"))

    let cloze = try #require(collection.notetypes.first { $0.name == "Cloze" })
    #expect(cloze.kind == .cloze)
    #expect(cloze.fields == ["Text", "Back Extra"])
  }

  @Test(arguments: ["collection.colpkg", "collection-legacy.colpkg", "n5-with-scheduling.apkg"])
  func readsNotesAndTheirCards(name: String) throws {
    let collection = try AnkiCollection(contentsOf: Self.fixture(name))

    let meet = try #require(collection.notes.first { $0.fields.first == "会う" })
    #expect(meet.guid == "kupB!kWE}<")
    #expect(meet.notetypeId == 2_000_494_194)
    #expect(meet.fields == ["会う", "あう", "to meet, to see"])

    let cards = collection.cards.filter { $0.noteId == meet.id }.sorted { $0.ordinal < $1.ordinal }
    let n5 = try #require(collection.decks.first { $0.path == Self.n5 })
    #expect(cards.map(\.ordinal) == [0, 1])
    #expect(cards.allSatisfy { $0.deckId == n5.id })
    #expect(cards.map(\.queue) == [.review, .suspended])

    let sentence = try #require(
      collection.notes.first { $0.fields.first?.hasPrefix("毎朝パン") == true })
    #expect(sentence.fields == ["毎朝パンを<b>食べます</b>。", "I eat bread every morning."])
    #expect(sentence.tags == ["handmade", "sentence"])
    let sentencesDeck = try #require(collection.decks.first { $0.path == Self.sentences })
    #expect(collection.cards.first { $0.noteId == sentence.id }?.deckId == sentencesDeck.id)
  }

  @Test(arguments: ["collection.colpkg", "collection-legacy.colpkg"])
  func mapsBorrowedCardsToTheirHomeDeck(name: String) throws {
    let collection = try AnkiCollection(contentsOf: Self.fixture(name))

    let cram = try #require(collection.decks.first(where: { $0.isFiltered }))
    let borrowed = collection.cards.filter { $0.filteredDeckId != nil }
    #expect(borrowed.count == 25)
    #expect(borrowed.allSatisfy { $0.filteredDeckId == cram.id && $0.deckId != cram.id })
    #expect(!collection.cards.contains { $0.deckId == cram.id })
  }

  @Test(arguments: ["collection.colpkg", "collection-legacy.colpkg", "n5-with-scheduling.apkg"])
  func readsTheReviewLog(name: String) throws {
    let reviews = try AnkiCollection(contentsOf: Self.fixture(name)).reviews

    #expect(reviews.count == 206)
    #expect(reviews.map(\.id) == reviews.map(\.id).sorted())
    let ratings = Dictionary(grouping: reviews, by: \.rating).mapValues(\.count)
    #expect(ratings == [nil: 80, .again: 20, .hard: 18, .good: 65, .easy: 23])
    let kinds = Dictionary(grouping: reviews, by: \.kind).mapValues(\.count)
    #expect(kinds == [.learning: 59, .review: 60, .relearning: 7, .manual: 80])
    #expect(reviews.filter { $0.kind == .manual }.allSatisfy { $0.rating == nil })

    let first = try #require(reviews.first)
    #expect(first.rating == .hard)
    #expect(first.interval == -330)
    #expect(first.reviewedAt == Date(timeIntervalSince1970: Double(first.id) / 1000))
  }

  @Test(arguments: ["collection.colpkg", "collection-legacy.colpkg", "n5-with-scheduling.apkg"])
  func readsFsrsMemoryState(name: String) throws {
    let cards = try AnkiCollection(contentsOf: Self.fixture(name)).cards

    #expect(cards.filter { $0.memoryState != nil }.count == 20)
    let first = try #require(cards.first { $0.id == 1 })
    #expect(first.memoryState == AnkiCard.MemoryState(stability: 0.2838, difficulty: 9.812))
    #expect(cards.filter { $0.queue == .new }.allSatisfy { $0.memoryState == nil })
  }

  @Test func readsASingleDeckExport() throws {
    let collection = try AnkiCollection(contentsOf: Self.fixture("n5-with-scheduling.apkg"))

    #expect(collection.format == .latest)
    #expect(collection.notes.count == 723)
    #expect(collection.cards.count == 1442)
    #expect(
      Set(collection.decks.map(\.path)) == [["Default"], Self.n5, Self.sentences, ["Cram"]])
    #expect(Set(collection.notetypes.map(\.name)) == ["Basic", "Cloze", "Open Anki JLPT Vocab"])
  }

  @Test(arguments: ["n5-upstream.apkg", "n5-zip64.apkg"])
  func readsTheOriginalLayoutSharedDecksUse(name: String) throws {
    let collection = try AnkiCollection(contentsOf: Self.fixture(name))

    #expect(collection.format == .legacy1)
    #expect(collection.notes.count == 718)
    #expect(collection.cards.count == 1436)
    #expect(collection.reviews.isEmpty)
    #expect(collection.notetypes.map(\.name) == ["Open Anki JLPT Vocab"])
    #expect(collection.notes.first?.fields == ["ああ", "ああ", "Ah!, Oh!"])
  }
}

@Suite struct AnkiPackageErrorTests {
  @Test func rejectsAFileThatIsNotAZipArchive() throws {
    let url = try scratchFile(Data("not a package".utf8))
    #expect(throws: AnkiPackageError.notAPackage) { try AnkiCollection(contentsOf: url) }
  }

  @Test func rejectsAnArchiveWithoutACollection() throws {
    // An empty ZIP: just the 22-byte end-of-central-directory record.
    let url = try scratchFile(Data([0x50, 0x4b, 0x05, 0x06] + [UInt8](repeating: 0, count: 18)))
    #expect(throws: AnkiPackageError.missingCollection) { try AnkiCollection(contentsOf: url) }
  }

  @Test func rejectsACorruptedEntry() throws {
    var bytes = try Data(contentsOf: AnkiCollectionTests.fixture("n5-upstream.apkg"))
    // Inside the stored collection.anki2, well past its local header.
    bytes[100_000] ^= 0xFF
    let url = try scratchFile(bytes)
    #expect(throws: AnkiPackageError.corruptEntry("collection.anki2")) {
      try AnkiCollection(contentsOf: url)
    }
  }

  @Test func reportsAMissingFile() {
    let url = URL(fileURLWithPath: "/nonexistent/\(UUID().uuidString).apkg")
    #expect {
      try AnkiCollection(contentsOf: url)
    } throws: { error in
      if case .unreadable = error as? AnkiPackageError { true } else { false }
    }
  }

  private func scratchFile(_ data: Data) throws -> URL {
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("AnkiWrapperTests-\(UUID().uuidString).apkg")
    try data.write(to: url)
    return url
  }
}

/// Decks that cannot be committed (unlicensed, or personal collections)
/// can still be checked locally:
/// `ANKI_WRAPPER_PACKAGES=/path/a.apkg:/path/b.colpkg swift test`.
@Suite struct LocalPackageTests {
  static let paths =
    ProcessInfo.processInfo.environment["ANKI_WRAPPER_PACKAGES"]?
    .split(separator: ":").map(String.init) ?? []

  @Test(.enabled(if: !paths.isEmpty), arguments: paths)
  func readsEveryNoteAndCard(path: String) throws {
    let collection = try AnkiCollection(contentsOf: URL(fileURLWithPath: path))
    let notetypes = Dictionary(uniqueKeysWithValues: collection.notetypes.map { ($0.id, $0) })
    let noteIds = Set(collection.notes.map(\.id))
    let deckIds = Set(collection.decks.map(\.id))

    #expect(!collection.notes.isEmpty)
    for note in collection.notes {
      #expect(note.fields.count == notetypes[note.notetypeId]?.fields.count)
    }
    #expect(
      collection.cards.allSatisfy { noteIds.contains($0.noteId) && deckIds.contains($0.deckId) })
  }
}

@Suite struct SyntheticPackageTests {
  static func hostile(_ name: String) throws -> URL {
    try AnkiCollectionTests.fixture("hostile/\(name)")
  }

  @Test func translatesV1SchedulerLearningAnswers() throws {
    let reviews = try AnkiCollection(contentsOf: Self.hostile("v1-scheduler.apkg")).reviews

    #expect(reviews.map(\.rating) == [.again, .good, .easy, .hard, .good])
    #expect(reviews.map(\.kind) == [.learning, .learning, .learning, .review, .relearning])
  }

  @Test func reportsABorrowedCardsHomeDue() throws {
    let collection = try AnkiCollection(contentsOf: Self.hostile("v1-scheduler.apkg"))

    let borrowed = try #require(collection.cards.first { $0.id == 2 })
    #expect(borrowed.deckId == 1)
    #expect(borrowed.filteredDeckId == 2)
    #expect(borrowed.due == 42)
    #expect(collection.cards.first { $0.id == 1 }?.due == 10)
  }

  @Test func rejectsAVersionTooLargeForAnyInteger() {
    #expect(throws: AnkiPackageError.unsupportedVersion(Int.max)) {
      try AnkiCollection(contentsOf: Self.hostile("meta-huge-version.apkg"))
    }
  }

  @Test func refusesAnOversizedMetaBeforeInflatingIt() {
    #expect(throws: AnkiPackageError.tooLarge("meta")) {
      try AnkiCollection(contentsOf: Self.hostile("meta-oversized.apkg"))
    }
  }

  @Test func rejectsAZip64RecordThatOverflows() {
    #expect(throws: AnkiPackageError.notAPackage) {
      try AnkiCollection(contentsOf: Self.hostile("zip64-overflow.apkg"))
    }
  }

  @Test func refusesAViewInPlaceOfATable() {
    #expect(throws: AnkiPackageError.database("notes is not a table")) {
      try AnkiCollection(contentsOf: Self.hostile("notes-view.apkg"))
    }
  }

  @Test(arguments: [
    "notes-generated-column.apkg", "notes-virtual-table.apkg", "notes-disguised-virtual-table.apkg",
  ])
  func refusesATableThatRunsCodeWhenRead(name: String) {
    #expect(throws: AnkiPackageError.database("notes is not a table")) {
      try AnkiCollection(contentsOf: Self.hostile(name))
    }
  }

  @Test(arguments: ["separator-field.apkg", "separator-deck-name.apkg"])
  func refusesContentsThatWouldOutgrowTheCapInMemory(name: String) {
    // A database of a few megabytes, well under the cap, with a field or a
    // deck name that splits into millions of strings.
    #expect(throws: AnkiPackageError.tooLarge("collection")) {
      try AnkiCollection(contentsOf: Self.hostile(name), maximumDatabaseSize: 10_000_000)
    }
  }

  @Test func chargesDeckJsonForWhatDecodingItCosts() {
    // A 1 MB deck name in a database far under the cap: decoding the JSON
    // around it costs tens of times its size.
    #expect(throws: AnkiPackageError.tooLarge("collection")) {
      try AnkiCollection(
        contentsOf: Self.hostile("large-deck-json.apkg"), maximumDatabaseSize: 20_000_000)
    }
  }

  @Test func readsTheSchedulerVersionFromAConfigOfAnySize() throws {
    // v2 behind a megabyte of padding: its learning Hard stays Hard.
    let reviews = try AnkiCollection(contentsOf: Self.hostile("oversized-conf.apkg")).reviews

    #expect(reviews.first?.kind == .learning)
    #expect(reviews.first(where: { $0.id == 2000 })?.rating == .hard)
  }

  @Test func ordersFieldsAndTemplatesItself() throws {
    let notetype = try #require(
      try AnkiCollection(contentsOf: Self.hostile("modern-reversed-rows.apkg")).notetypes.first)

    #expect(notetype.fields == ["Front", "Back", "Extra"])
    #expect(notetype.templates.map(\.name) == ["Recognition", "Production"])
  }

  @Test func refusesATableThatRedefinesItsRowid() {
    #expect(throws: AnkiPackageError.database("revlog is not a table")) {
      try AnkiCollection(contentsOf: Self.hostile("revlog-rowid-column.apkg"))
    }
  }

  @Test func countsRowsFromTheTableNotAnIndexTheFileSupplies() {
    // 5,000 reviews behind an index that counts none: 88-byte rows cost
    // about 440 KB, past a 300 KB cap only if they are counted.
    #expect(throws: AnkiPackageError.tooLarge("collection")) {
      try AnkiCollection(
        contentsOf: Self.hostile("lying-revlog-index.apkg"), maximumDatabaseSize: 300_000)
    }
  }

  @Test func chargesGroupedFieldRowsForTheirContainers() {
    #expect(throws: AnkiPackageError.tooLarge("collection")) {
      try AnkiCollection(
        contentsOf: Self.hostile("modern-many-fields.apkg"), maximumDatabaseSize: 10_000_000)
    }
  }

  @Test func refusesADatabaseLargerThanTheCapBeforeWritingItAll() throws {
    let url = try AnkiCollectionTests.fixture("collection.colpkg")

    // The compressed entry is about 147 KB; the database it expands to
    // about 602 KB, so these two caps stop each stage.
    #expect(throws: AnkiPackageError.tooLarge("collection.anki21b")) {
      try AnkiCollection(contentsOf: url, maximumDatabaseSize: 100_000)
    }
    #expect(throws: AnkiPackageError.tooLarge("collection.anki21b")) {
      try AnkiCollection(contentsOf: url, maximumDatabaseSize: 300_000)
    }
    #expect(throws: AnkiPackageError.tooLarge("collection.anki2")) {
      try AnkiCollection(
        contentsOf: AnkiCollectionTests.fixture("n5-upstream.apkg"), maximumDatabaseSize: 1_000)
    }
  }
}
