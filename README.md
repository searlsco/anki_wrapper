# AnkiWrapper

Read [Anki](https://apps.ankiweb.net) decks and collections in Swift.

AnkiWrapper opens the `.apkg` and `.colpkg` files Anki exports and hands
back plain Swift values: decks, notetypes, notes, cards, and the review
log. It is meant for apps that want to bring an Anki learner's material
and history along with them.

```swift
import AnkiWrapper

let collection = try AnkiCollection(contentsOf: url)

for deck in collection.decks where !deck.isFiltered {
  print(deck.name)  // "Japanese::Vocab"
}

let notetypes = Dictionary(uniqueKeysWithValues: collection.notetypes.map { ($0.id, $0) })
for note in collection.notes {
  let fieldNames = notetypes[note.notetypeId]?.fields ?? []
  print(Dictionary(uniqueKeysWithValues: zip(fieldNames, note.fields)))
}

let passes = collection.reviews.filter { ($0.rating ?? .again) != .again }
```

Reading blocks on file I/O and decompression, so do it off the main thread.

## What it reads

| Layout | Written by | Collection entry |
|---|---|---|
| `.latest` | Anki 2.1.50+ (desktop, AnkiMobile, AnkiDroid) | `collection.anki21b`, zstd-compressed |
| `.legacy2` | Anki with "Support older Anki versions" checked | `collection.anki21` |
| `.legacy1` | AnkiWeb shared decks, genanki, Anki before 2.1 | `collection.anki2` |

- **Collections and decks.** A `.colpkg` holds a learner's whole
  collection; AnkiMobile can only export this. An `.apkg` holds one deck and
  its subdecks.
- **Review history** comes through only when the learner exported with
  "Include scheduling information". Anki unchecks that box when exporting
  from a deck's gear menu.
- **Filtered decks.** A card borrowed by a filtered deck reports its home
  deck as `deckId` and the filtered deck as `filteredDeckId`.
- **Large archives.** Entries are read through the ZIP central directory,
  ZIP64 included, so gigabytes of media cost nothing.
- **FSRS.** Cards in collections that schedule with FSRS carry their
  `memoryState` (stability and difficulty). Review cards' `due` counts days
  from the day of `createdAt`.
- **Old collections.** Review ratings from Anki's retired v1 scheduler are
  translated to today's four buttons, as Anki itself does on import.
- **Untrusted files.** A package is treated as hostile input: sizes are
  checked before anything is inflated, the collection database is capped
  at `maximumDatabaseSize` (2 GiB by default), and its schema may not stand
  a view in for a table or run code.

Field contents are returned exactly as Anki stores them: HTML, furigana
brackets (`漢字[かんじ]`), cloze markup and `[sound:…]` references are
left for your app to interpret. Media files are not read.

AnkiWrapper is written from Anki's file formats, not from Anki's
AGPL-licensed source.

## Installation

```swift
.package(url: "https://github.com/searlsco/anki_wrapper.git", from: "0.1.0")
```

Then depend on the `AnkiWrapper` product. The one dependency is
[zstd](https://github.com/facebook/zstd), which Apple's SDKs do not
provide. Supports iOS 17, macOS 14, tvOS 17 and visionOS 1 or later.

## Development

```bash
./script/test               # lint + tests
./script/format             # swift-format in place
./script/generate_fixtures  # rebuild test fixtures with Anki's own library
./script/release minor      # tag and push a release
```

To check packages that can't be committed, such as your own collection:

```bash
ANKI_WRAPPER_PACKAGES=~/collection.colpkg:~/deck.apkg ./script/test
```

The test fixtures are built from the
[Open Anki JLPT decks](https://github.com/jamsinclair/open-anki-jlpt-decks)
(MIT), whose vocabulary comes from [tanos.co.uk](http://www.tanos.co.uk/jlpt/)
under [CC BY](http://www.tanos.co.uk/jlpt/sharing/). The sentence and cloze
notes were written for this project.

## License

MIT
