import Foundation

/// Everything a learner's Anki export holds, read into plain values.
///
/// Reading opens the archive, decompresses its collection into a temporary
/// directory, copies every deck, notetype, note, card and review out of it,
/// and deletes the temporary files before returning. Media is not read.
///
/// Reading blocks on file I/O and decompression, so call it off the main
/// thread.
public struct AnkiCollection: Sendable, Hashable {
  /// The largest collection database `init(contentsOf:)` will decompress
  /// unless told otherwise: well past any real learner's collection, and
  /// small enough that a hostile package cannot fill a device's disk.
  public static let defaultMaximumDatabaseSize: Int64 = 2 << 30

  /// Which of Anki's package layouts the file used.
  public var format: AnkiPackageFormat
  /// When the collection was created. Review cards' `due` counts days from
  /// the day this falls in.
  public var createdAt: Date
  public var decks: [AnkiDeck]
  public var notetypes: [AnkiNotetype]
  public var notes: [AnkiNote]
  public var cards: [AnkiCard]
  /// The review log, oldest first.
  public var reviews: [AnkiReview]

  public init(
    format: AnkiPackageFormat, createdAt: Date, decks: [AnkiDeck], notetypes: [AnkiNotetype],
    notes: [AnkiNote], cards: [AnkiCard], reviews: [AnkiReview]
  ) {
    self.format = format
    self.createdAt = createdAt
    self.decks = decks
    self.notetypes = notetypes
    self.notes = notes
    self.cards = cards
    self.reviews = reviews
  }

  /// Reads a `.colpkg` (a whole collection) or an `.apkg` (one deck and its
  /// subdecks), in any layout Anki has written: the current zstd-compressed
  /// one, the "support older Anki versions" one, and the original one that
  /// AnkiWeb shared decks and genanki still produce.
  ///
  /// A collection database larger than `maximumDatabaseSize` bytes once
  /// decompressed is refused with `AnkiPackageError.tooLarge` before it is
  /// written out in full.
  public init(
    contentsOf url: URL, maximumDatabaseSize: Int64 = defaultMaximumDatabaseSize
  ) throws(AnkiPackageError) {
    self = try PackageReader.read(url, maximumDatabaseSize: maximumDatabaseSize)
  }
}

/// The layout of an Anki package, named after Anki's own
/// `PackageMetadata.Version`.
public enum AnkiPackageFormat: Sendable, Hashable {
  /// `collection.anki2`: AnkiWeb shared decks, genanki, and Anki before 2.1.
  case legacy1
  /// `collection.anki21`: exports made with "Support older Anki versions".
  case legacy2
  /// `collection.anki21b`: zstd-compressed, Anki 2.1.50 and later.
  case latest
}

public struct AnkiDeck: Sendable, Hashable, Identifiable {
  public var id: Int64
  /// The deck's name split at Anki's `::` separators, root first.
  public var path: [String]
  /// A filtered ("custom study") deck only borrows cards; each card's
  /// `deckId` still names its home deck.
  public var isFiltered: Bool

  public init(id: Int64, path: [String], isFiltered: Bool) {
    self.id = id
    self.path = path
    self.isFiltered = isFiltered
  }

  /// The full name as Anki shows it, such as `Japanese::Vocab`.
  public var name: String { path.joined(separator: "::") }
}

public struct AnkiNotetype: Sendable, Hashable, Identifiable {
  public enum Kind: Sendable, Hashable {
    case standard
    case cloze
  }

  public var id: Int64
  public var name: String
  public var kind: Kind
  /// In field order, which is the order of every note's `fields`.
  public var fields: [String]
  /// In template order, which is each card's `ordinal` for standard
  /// notetypes. A cloze notetype has one template, and its cards' ordinals
  /// count cloze numbers instead.
  public var templates: [AnkiTemplate]

  public init(id: Int64, name: String, kind: Kind, fields: [String], templates: [AnkiTemplate]) {
    self.id = id
    self.name = name
    self.kind = kind
    self.fields = fields
    self.templates = templates
  }
}

public struct AnkiTemplate: Sendable, Hashable {
  public var name: String
  /// The front's template source, such as `{{Front}}`.
  public var questionFormat: String
  /// The back's template source, such as `{{FrontSide}}<hr id=answer>{{Back}}`.
  public var answerFormat: String

  public init(name: String, questionFormat: String, answerFormat: String) {
    self.name = name
    self.questionFormat = questionFormat
    self.answerFormat = answerFormat
  }
}

public struct AnkiNote: Sendable, Hashable, Identifiable {
  public var id: Int64
  /// Stable across exports and collections: what Anki itself matches on
  /// when the same deck is imported again.
  public var guid: String
  public var notetypeId: Int64
  public var modifiedAt: Date
  public var tags: [String]
  /// Raw field contents in the notetype's field order: HTML, furigana
  /// brackets, cloze markup and `[sound:…]` references are left as Anki
  /// stores them.
  public var fields: [String]

  public init(
    id: Int64, guid: String, notetypeId: Int64, modifiedAt: Date, tags: [String], fields: [String]
  ) {
    self.id = id
    self.guid = guid
    self.notetypeId = notetypeId
    self.modifiedAt = modifiedAt
    self.tags = tags
    self.fields = fields
  }
}

public struct AnkiCard: Sendable, Hashable, Identifiable {
  /// Where a card is in its life, from Anki's `cards.type`.
  public enum Kind: Sendable, Hashable {
    case new
    case learning
    case review
    case relearning
    case unknown(Int)
  }

  /// What Anki will do with a card next, from Anki's `cards.queue`.
  public enum Queue: Sendable, Hashable {
    case suspended
    case buriedBySibling
    case buriedByUser
    case new
    case learning
    case review
    case dayLearning
    case preview
    case unknown(Int)
  }

  /// FSRS's model of how well the learner knows a card, kept by
  /// collections that schedule with FSRS.
  public struct MemoryState: Sendable, Hashable {
    /// Days until recall probability falls to 90%.
    public var stability: Double
    /// From 1 (easiest) to 10 (hardest).
    public var difficulty: Double

    public init(stability: Double, difficulty: Double) {
      self.stability = stability
      self.difficulty = difficulty
    }
  }

  public var id: Int64
  public var noteId: Int64
  /// The card's home deck, even while a filtered deck has borrowed it.
  public var deckId: Int64
  /// The filtered deck currently holding the card, if any.
  public var filteredDeckId: Int64?
  /// Which template (or, for cloze notetypes, which cloze number minus one)
  /// produced the card.
  public var ordinal: Int
  public var kind: Kind
  public var queue: Queue
  /// For new cards, the position Anki introduces them in; for review
  /// and day-learning cards, days since the day of
  /// `AnkiCollection.createdAt`; for learning cards, seconds since 1970. A
  /// card a filtered deck has borrowed reports the value its home deck
  /// will restore.
  public var due: Int64
  /// Days for review and relearning cards; zero for new and learning ones.
  public var interval: Int64
  /// Ease in permille (2500 is 250%); zero for new cards. Collections that
  /// schedule with FSRS keep writing it but schedule from `memoryState`.
  public var easeFactor: Int
  public var reviewCount: Int
  public var lapseCount: Int
  /// Present when the collection schedules this card with FSRS.
  public var memoryState: MemoryState?

  public init(
    id: Int64, noteId: Int64, deckId: Int64, filteredDeckId: Int64?, ordinal: Int, kind: Kind,
    queue: Queue, due: Int64, interval: Int64, easeFactor: Int, reviewCount: Int, lapseCount: Int,
    memoryState: MemoryState? = nil
  ) {
    self.id = id
    self.noteId = noteId
    self.deckId = deckId
    self.filteredDeckId = filteredDeckId
    self.ordinal = ordinal
    self.kind = kind
    self.queue = queue
    self.due = due
    self.interval = interval
    self.easeFactor = easeFactor
    self.reviewCount = reviewCount
    self.lapseCount = lapseCount
    self.memoryState = memoryState
  }
}

public struct AnkiReview: Sendable, Hashable, Identifiable {
  /// The answer button pressed. Collections from Anki's retired v1
  /// scheduler numbered learning answers differently; those are
  /// translated to these buttons on reading.
  public enum Rating: Int, Sendable, Hashable {
    case again = 1
    case hard = 2
    case good = 3
    case easy = 4
  }

  /// Why the row was logged, from Anki's `revlog.type`.
  public enum Kind: Sendable, Hashable {
    case learning
    case review
    case relearning
    /// Answered in a filtered deck without rescheduling.
    case filtered
    /// Rescheduled by hand (set due date, forget); no answer was given.
    case manual
    /// Rescheduled in bulk, such as by FSRS "reschedule cards on change".
    case rescheduled
    case unknown(Int)
  }

  /// Milliseconds since 1970 of the review, which Anki also uses as the id.
  public var id: Int64
  public var cardId: Int64
  /// `nil` when no button was pressed, as for manual rescheduling.
  public var rating: Rating?
  public var kind: Kind
  /// The interval after this review: days when positive, seconds when
  /// negative.
  public var interval: Int64
  /// The interval before this review, in the same units.
  public var lastInterval: Int64
  /// Ease in permille after this review. Collections that schedule with
  /// FSRS store a transformed difficulty here instead.
  public var easeFactor: Int
  /// How long the learner took to answer.
  public var duration: Duration

  public init(
    id: Int64, cardId: Int64, rating: Rating?, kind: Kind, interval: Int64, lastInterval: Int64,
    easeFactor: Int, duration: Duration
  ) {
    self.id = id
    self.cardId = cardId
    self.rating = rating
    self.kind = kind
    self.interval = interval
    self.lastInterval = lastInterval
    self.easeFactor = easeFactor
    self.duration = duration
  }

  public var reviewedAt: Date { Date(timeIntervalSince1970: Double(id) / 1000) }
}

public enum AnkiPackageError: Error, Sendable, Hashable {
  /// The file could not be opened or read.
  case unreadable(String)
  /// The file is not a ZIP archive, so not an Anki package.
  case notAPackage
  /// The archive holds no collection database Anki would recognize.
  case missingCollection
  /// The package was written by a newer Anki than this library knows.
  case unsupportedVersion(Int)
  /// An entry uses a ZIP feature Anki never writes, such as encryption.
  case unsupportedEntry(String)
  /// An entry failed to decompress or its checksum did not match.
  case corruptEntry(String)
  /// The collection database could not be read.
  case database(String)
  /// An entry decompresses to more than the reader was allowed to write.
  case tooLarge(String)
}
