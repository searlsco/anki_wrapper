# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-09-28

### Added

- `AnkiCollection(contentsOf:maximumDatabaseSize:)` reads `.apkg` and
  `.colpkg` files in all three of Anki's layouts into decks, notetypes,
  notes, cards and the review log, with the collection's creation time and
  each FSRS card's memory state.
- Ratings from Anki's v1 scheduler are translated to today's buttons.
- Malformed packages fail with `AnkiPackageError` instead of crashing,
  hanging, or filling the disk.
