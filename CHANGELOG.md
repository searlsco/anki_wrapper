# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.4] - 2026-09-28

### Fixed

- A legacy collection's scheduler version is read however large its
  settings are, so a v2 collection is never mistaken for v1.
- Grouped field and template rows are charged for their containers.

## [0.1.3] - 2026-09-28

### Fixed

- A virtual table disguised by the wording of its stored definition is
  refused: SQLite's own classification decides what is a plain table.
- Each table's rows are charged and reserved before reading, so arrays
  never regrow past what the memory cap allowed.

## [0.1.2] - 2026-09-28

### Fixed

- Collection settings, card data and protobuf blobs can no longer cost far
  more memory than the cap charges: oversized settings are ignored, deck
  and notetype JSON is charged for what decoding it costs, and protobuf
  fields nobody reads are never kept.

## [0.1.1] - 2026-09-28

### Fixed

- A legacy deck name made of `::` separators is charged against the memory
  cap before it is split, like every other field.

## [0.1.0] - 2026-09-28

### Added

- `AnkiCollection(contentsOf:maximumDatabaseSize:)` reads `.apkg` and
  `.colpkg` files in all three of Anki's layouts into decks, notetypes,
  notes, cards and the review log, with the collection's creation time and
  each FSRS card's memory state.
- Ratings from Anki's v1 scheduler are translated to today's buttons.
- Malformed packages fail with `AnkiPackageError` instead of crashing,
  hanging, or filling the disk.
