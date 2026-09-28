# AnkiWrapper

A public, read-only Swift package that turns Anki `.apkg` and `.colpkg`
exports into plain values. Repo: `github.com/searlsco/anki_wrapper`.
Module and product are both `AnkiWrapper`. Its first consumer is
[Memory Hole](https://github.com/searls/memory_hole), whose
`docs/ANKI_IMPORT.md` explains why the package exists.

## Scope

- **Read only.** No writing or exporting.
- **Knows nothing about languages.** No HTML or furigana cleanup, no
  field-role guessing, no dictionaries: consumers interpret fields.
- **No media** until a consumer needs it.
- **Clean room.** Anki is AGPL. Work from observed files, the `.proto`
  definitions and the manual; never port Anki's source.

## Dependencies

`facebook/zstd` only (Apple's SDKs have no zstd). ZIP is hand-rolled on
Apple's Compression; SQLite is the system library. Apple platforms only.
Adding a dependency needs Justin's approval.

## Testing

- `./script/test` lints and runs Swift Testing.
- Fixtures come from `./script/generate_fixtures`, which drives Anki's own
  Python library, so every layout is exactly what Anki writes. Expected
  values in tests are measured from the fixtures independently (Python
  `sqlite3` plus the `zstd` CLI), never through this library.
- Unlicensed or personal decks never get committed. Check them locally with
  `ANKI_WRAPPER_PACKAGES`.

## Releases

Semver, bare tags (`0.1.0`). `./script/release <major|minor|patch>` rolls
`CHANGELOG.md`, runs the tests, tags and pushes; the release workflow
creates the GitHub release.
