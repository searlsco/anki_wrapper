"""Builds small malformed packages that must fail cleanly (or, for the v1
scheduler case, read correctly). Run through script/generate_fixtures."""

import io
import json
import os
import sqlite3
import struct
import sys
import tempfile
import zipfile

out_dir = os.path.abspath(sys.argv[1])
os.makedirs(out_dir, exist_ok=True)


def write(name, data):
    with open(os.path.join(out_dir, name), "wb") as f:
        f.write(data)


def zip_bytes(entries, method=zipfile.ZIP_STORED):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", method) as archive:
        for name, data in entries:
            archive.writestr(name, data)
    return buffer.getvalue()


def legacy_collection(build, decks=None):
    """A minimal schema 11 collection, adjusted by `build(db)`."""
    with tempfile.TemporaryDirectory() as scratch:
        path = os.path.join(scratch, "collection.anki2")
        db = sqlite3.connect(path)
        models = {
            "1": {
                "name": "Basic",
                "type": 0,
                "flds": [{"name": "Front", "ord": 0}, {"name": "Back", "ord": 1}],
                "tmpls": [
                    {"name": "Card 1", "ord": 0, "qfmt": "{{Front}}", "afmt": "{{Back}}"}
                ],
            }
        }
        decks = decks or {"1": {"name": "Default", "dyn": 0}, "2": {"name": "Cram", "dyn": 1}}
        db.executescript(
            """
            CREATE TABLE col (id integer PRIMARY KEY, crt integer, conf text,
              models text, decks text);
            CREATE TABLE cards (id integer PRIMARY KEY, nid integer, did integer,
              odid integer, ord integer, type integer, queue integer, due integer,
              ivl integer, factor integer, reps integer, lapses integer,
              odue integer, data text);
            CREATE TABLE revlog (id integer PRIMARY KEY, cid integer, ease integer,
              ivl integer, lastIvl integer, factor integer, time integer,
              type integer);
            """
        )
        db.execute(
            "INSERT INTO col VALUES (1, 1400000000, '{}', ?, ?)",
            (json.dumps(models), json.dumps(decks)),
        )
        build(db)
        db.commit()
        db.close()
        with open(path, "rb") as f:
            return f.read()


# A `meta` version too large for any integer type.
write("meta-huge-version.apkg", zip_bytes([("meta", b"\x08" + b"\xff" * 9 + b"\x01")]))

# A `meta` that inflates past the size any real one has.
write("meta-oversized.apkg", zip_bytes([("meta", b"\0" * 100_000)], zipfile.ZIP_DEFLATED))

# A ZIP64 end record whose directory offset plus size overflows.
base = zip_bytes([("x", b"hi")])
body = base[: base.rfind(b"PK\x05\x06")]
zip64_record = struct.pack(
    "<IQHHIIQQQQ", 0x06064B50, 44, 45, 45, 0, 0, 1, 1, 0x10, 0xFFFFFFFFFFFFFFF8
)
locator = struct.pack("<IIQI", 0x07064B50, 0, len(body), 1)
end = struct.pack("<IHHHHIIH", 0x06054B50, 0, 0, 0xFFFF, 0xFFFF, 0xFFFFFFFF, 0xFFFFFFFF, 0)
write("zip64-overflow.apkg", body + zip64_record + locator + end)


# A `notes` view in place of the table, which could run any query.
def notes_view(db):
    db.execute("CREATE VIEW notes AS SELECT 1 AS id, '' AS guid, 1 AS mid, 0 AS mod, "
               "'' AS tags, '' AS flds")


write("notes-view.apkg", zip_bytes([("collection.anki2", legacy_collection(notes_view))]))


# A collection from the v1 scheduler, which numbered learning answers 1 to 3,
# with a second card borrowed by a filtered deck.
def v1_reviews(db):
    db.execute("CREATE TABLE notes (id integer PRIMARY KEY, guid text, mid integer, "
               "mod integer, tags text, flds text)")
    db.execute("INSERT INTO notes VALUES (1, 'guid', 1, 0, '', 'front\x1fback')")
    db.execute("INSERT INTO cards VALUES (1, 1, 1, 0, 0, 2, 2, 10, 3, 2500, 4, 0, 0, '')")
    db.execute("INSERT INTO cards VALUES (2, 1, 2, 1, 1, 2, 2, -100000, 3, 2500, 4, 0, 42, '')")
    rows = [
        (1000, 0, 1),  # learning Again
        (2000, 0, 2),  # learning Good under v1
        (3000, 0, 3),  # learning Easy under v1
        (4000, 1, 2),  # review Hard, unchanged
        (5000, 2, 2),  # relearning Good under v1
    ]
    for review_id, kind, ease in rows:
        db.execute(
            "INSERT INTO revlog VALUES (?, 1, ?, 1, 0, 2500, 1000, ?)", (review_id, ease, kind)
        )


write("v1-scheduler.apkg", zip_bytes([("collection.anki2", legacy_collection(v1_reviews))]))


# A generated `flds` column: still a table, but reading a row runs whatever
# expression the file chose.
def generated_fields(db):
    db.execute("CREATE TABLE notes (id integer PRIMARY KEY, guid text, mid integer, "
               "mod integer, tags text, raw text, "
               "flds text GENERATED ALWAYS AS (printf('%.*c', 1000, 'x')) VIRTUAL)")


write(
    "notes-generated-column.apkg",
    zip_bytes([("collection.anki2", legacy_collection(generated_fields))]),
)


# A virtual table in place of `notes`.
def virtual_notes(db):
    db.execute("CREATE VIRTUAL TABLE notes USING fts5(guid, flds)")


write(
    "notes-virtual-table.apkg",
    zip_bytes([("collection.anki2", legacy_collection(virtual_notes))]),
)


# A 2 MB field of nothing but separators: a small file that would expand
# into two million strings.
def separator_field(db):
    db.execute("CREATE TABLE notes (id integer PRIMARY KEY, guid text, mid integer, "
               "mod integer, tags text, flds text)")
    db.execute("INSERT INTO notes VALUES (1, 'guid', 1, 0, '', ?)", ("\x1f" * 2_000_000,))


write(
    "separator-field.apkg",
    zip_bytes([("collection.anki2", legacy_collection(separator_field))], zipfile.ZIP_DEFLATED),
)


def empty_notes(db):
    db.execute("CREATE TABLE notes (id integer PRIMARY KEY, guid text, mid integer, "
               "mod integer, tags text, flds text)")


# A deck name of nothing but separators: a small file whose one name would
# split into two million pieces.
write(
    "separator-deck-name.apkg",
    zip_bytes(
        [("collection.anki2", legacy_collection(empty_notes, {"1": {"name": "::" * 2_000_000, "dyn": 0}}))],
        zipfile.ZIP_DEFLATED,
    ),
)
