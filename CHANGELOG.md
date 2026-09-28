# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

### Fixed

- A schema row's parse cost is bounded (64 columns, 64 KiB of SQL), so
  the schema work limit bounds the whole load.

## [0.1.9] - 2026-09-28

### Fixed

- Loading a collection's schema runs under a work limit, and anything but
  plain tables and indexes is refused before any other query, so a small
  file can't pin a core with thousands of indexes or a chain of views.

## [0.1.8] - 2026-09-28

### Fixed

- Splitting a field builds its pieces in one reserved array, within what
  the memory cap charged, rather than through a second array of them all.

## [0.1.7] - 2026-09-28

### Fixed

- A table declaring its own `rowid` column is refused, since it would turn
  reading in rowid order back into a sort.
- Every value is charged before it is copied out of the database, and card
  data or settings too large to be real are dropped by SQLite unread.

## [0.1.6] - 2026-09-28

### Fixed

- Rows are counted from each table itself, never an index the file
  supplies, before memory is reserved for them.
- Only the entries a collection needs are kept from the ZIP directory, and
  a directory past 64 MiB is refused.

## [0.1.5] - 2026-09-28

### Fixed

- No query asks SQLite to sort: rows are read in stored order, which a
  hostile schema could otherwise turn into an unbudgeted in-memory sort.
- The `unicase` collation compares bytes without allocating.
- A failed database open no longer closes its handle twice.

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
