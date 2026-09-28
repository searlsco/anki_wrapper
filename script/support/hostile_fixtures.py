"""Builds small malformed packages that must fail cleanly (or, for the v1
scheduler case, read correctly). Run through script/generate_fixtures."""

import io
import json
import os
import sqlite3
import struct
import subprocess
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


def legacy_collection(build, decks=None, page_size=None):
    """A minimal schema 11 collection, adjusted by `build(db)`."""
    with tempfile.TemporaryDirectory() as scratch:
        path = os.path.join(scratch, "collection.anki2")
        db = sqlite3.connect(path)
        if page_size:
            db.execute(f"PRAGMA page_size = {page_size}")
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


# Deck JSON whose decoding would cost far more than the JSON's own size.
write(
    "large-deck-json.apkg",
    zip_bytes(
        [("collection.anki2", legacy_collection(empty_notes, {"1": {"name": "x" * 1_000_000, "dyn": 0}}))],
        zipfile.ZIP_DEFLATED,
    ),
)


# A collection config far larger than any real one, which is ignored rather
# than decoded.
def oversized_conf(db):
    v1_reviews(db)
    db.execute("UPDATE col SET conf = ?", ('{"pad":"' + "0" * 1_000_000 + '","schedVer":2}',))


write(
    "oversized-conf.apkg",
    zip_bytes([("collection.anki2", legacy_collection(oversized_conf))], zipfile.ZIP_DEFLATED),
)


# A virtual table whose stored definition hides behind a comment, so only
# SQLite's own classification can tell.
def disguised_virtual_notes(db):
    db.execute("CREATE VIRTUAL TABLE notes USING rtree(id, a, b)")
    db.commit()
    db.setconfig(sqlite3.SQLITE_DBCONFIG_DEFENSIVE, False)
    db.execute("PRAGMA writable_schema = ON")
    db.execute(
        "UPDATE sqlite_master SET sql = 'CREATE /*x*/ VIRTUAL TABLE notes USING rtree(id, a, b)' "
        "WHERE name = 'notes'")
    db.execute("PRAGMA writable_schema = OFF")


write(
    "notes-disguised-virtual-table.apkg",
    zip_bytes([("collection.anki2", legacy_collection(disguised_virtual_notes))]),
)


# A modern collection whose fields table holds a hundred thousand rows, each
# under a notetype of its own: tiny on disk, costly to group in memory.
def modern_many_fields(fill=None):
    with tempfile.TemporaryDirectory() as scratch:
        path = os.path.join(scratch, "collection.anki21b")
        db = sqlite3.connect(os.path.join(scratch, "collection.sqlite"))
        db.executescript(
            """
            CREATE TABLE col (id integer PRIMARY KEY, crt integer, conf text);
            CREATE TABLE notes (id integer PRIMARY KEY, guid text, mid integer, mod integer,
              tags text, flds text);
            CREATE TABLE cards (id integer PRIMARY KEY, nid integer, did integer, odid integer,
              ord integer, type integer, queue integer, due integer, ivl integer,
              factor integer, reps integer, lapses integer, odue integer, data text);
            CREATE TABLE revlog (id integer PRIMARY KEY, cid integer, ease integer, ivl integer,
              lastIvl integer, factor integer, time integer, type integer);
            CREATE TABLE decks (id integer PRIMARY KEY, name text, kind blob);
            CREATE TABLE notetypes (id integer PRIMARY KEY, name text, config blob);
            CREATE TABLE fields (ntid integer, ord integer, name text, config blob);
            CREATE TABLE templates (ntid integer, ord integer, name text, config blob);
            CREATE TABLE config (KEY text, val blob);
            INSERT INTO col VALUES (1, 1400000000, '{}');
            """
        )
        if fill:
            fill(db)
        else:
            db.executemany(
                "INSERT INTO fields VALUES (?, 0, '', x'')", ((i,) for i in range(100_000))
            )
        db.commit()
        db.close()
        subprocess.run(
            ["zstd", "-q", "-19", os.path.join(scratch, "collection.sqlite"), "-o", path],
            check=True)
        with open(path, "rb") as f:
            return f.read()


write(
    "modern-many-fields.apkg",
    zip_bytes([("meta", b"\x08\x03"), ("collection.anki21b", modern_many_fields())]),
)


# A notetype whose field and template rows are stored in reverse order:
# the reader orders them itself rather than asking SQLite to sort.
def reversed_rows(db):
    db.execute("INSERT INTO notetypes VALUES (1, 'Vocab', x'')")
    for ord_, name in reversed(list(enumerate(["Front", "Back", "Extra"]))):
        db.execute("INSERT INTO fields VALUES (1, ?, ?, x'')", (ord_, name))
    for ord_, name in reversed(list(enumerate(["Recognition", "Production"]))):
        db.execute("INSERT INTO templates VALUES (1, ?, ?, x'')", (ord_, name))


write(
    "modern-reversed-rows.apkg",
    zip_bytes([("meta", b"\x08\x03"), ("collection.anki21b", modern_many_fields(reversed_rows))]),
)


# A revlog whose index has been swapped for an empty table's, so counting
# through the index says zero while the table holds every row.
def lying_revlog_index(db):
    empty_notes(db)
    db.execute("CREATE INDEX ix_revlog_cid ON revlog (cid)")
    db.execute("CREATE TABLE decoy (x integer)")
    db.execute("CREATE INDEX ix_decoy ON decoy (x)")
    db.executemany(
        "INSERT INTO revlog VALUES (?, 1, 3, 1, 0, 2500, 1000, 1)", ((i,) for i in range(1, 5001))
    )
    db.commit()
    pages = dict(db.execute(
        "SELECT name, rootpage FROM sqlite_master WHERE name IN ('ix_revlog_cid', 'ix_decoy')"))
    db.setconfig(sqlite3.SQLITE_DBCONFIG_DEFENSIVE, False)
    db.execute("PRAGMA writable_schema = ON")
    db.execute("UPDATE sqlite_master SET rootpage = ? WHERE name = 'ix_revlog_cid'", (pages["ix_decoy"],))
    db.execute("UPDATE sqlite_master SET rootpage = ? WHERE name = 'ix_decoy'", (pages["ix_revlog_cid"],))
    db.execute("PRAGMA writable_schema = OFF")


write(
    "lying-revlog-index.apkg",
    zip_bytes([("collection.anki2", legacy_collection(lying_revlog_index))], zipfile.ZIP_DEFLATED),
)


# A revlog declaring a column of its own named rowid.
def revlog_rowid_column(db):
    empty_notes(db)
    db.execute("DROP TABLE revlog")
    db.execute("CREATE TABLE revlog (rowid text, id integer, cid integer, ease integer, "
               "ivl integer, lastIvl integer, factor integer, time integer, type integer)")


write(
    "revlog-rowid-column.apkg",
    zip_bytes([("collection.anki2", legacy_collection(revlog_rowid_column))]),
)


# Views that each reference the one before twice: compiling them for any
# schema query costs time exponential in the chain.
def view_chain(db):
    empty_notes(db)
    db.execute("CREATE VIEW v0 AS SELECT 1 AS x")
    for i in range(1, 40):
        db.execute(f"CREATE VIEW v{i} AS SELECT * FROM v{i - 1} UNION ALL SELECT * FROM v{i - 1}")


write("view-chain.apkg", zip_bytes([("collection.anki2", legacy_collection(view_chain))]))


# Twenty thousand indexes on one table: loading the schema checks each
# against every other.
def many_indexes(db):
    empty_notes(db)
    for i in range(20_000):
        db.execute(f"CREATE INDEX ix{i} ON notes (id)")


write(
    "many-indexes.apkg",
    zip_bytes([("collection.anki2", legacy_collection(many_indexes))], zipfile.ZIP_DEFLATED),
)


# Indexes over hundreds of columns each: every row of the schema costs a
# long parse between the instructions a work limit can count.
def wide_indexes(db):
    empty_notes(db)
    columns = ", ".join(f"c{i}" for i in range(500))
    db.execute(f"CREATE TABLE wide ({columns})")
    backwards = ", ".join(f"c{i}" for i in reversed(range(500)))
    for i in range(50):
        db.execute(f"CREATE INDEX wix{i} ON wide ({backwards})")


write(
    "wide-indexes.apkg",
    zip_bytes([("collection.anki2", legacy_collection(wide_indexes))], zipfile.ZIP_DEFLATED),
)


# A revlog b-tree whose interior pages point every entry at the same child,
# a chain deep enough that reading it visits the one leaf billions of times.
# Only an integrity check notices.
def revlog_rows(db):
    empty_notes(db)
    db.executemany(
        "INSERT INTO revlog VALUES (?, 1, 3, 1, 0, 2500, 1000, 1)", ((i,) for i in range(1, 20_001))
    )


def looping_btree():
    data = bytearray(legacy_collection(revlog_rows, page_size=512))
    with tempfile.TemporaryDirectory() as scratch:
        path = os.path.join(scratch, "c.anki2")
        with open(path, "wb") as f:
            f.write(data)
        db = sqlite3.connect(path)
        root = db.execute("SELECT rootpage FROM sqlite_master WHERE name = 'revlog'").fetchone()[0]
        db.close()
    size = 512

    def header(page):
        return (page - 1) * size + (100 if page == 1 else 0)

    pages = len(data) // size
    interior = [p for p in range(2, pages + 1) if data[header(p)] == 5 and p != root]
    leaf = next(p for p in range(2, pages + 1) if data[header(p)] == 13)
    chain = [root] + interior[:8]
    for page, child in zip(chain, chain[1:] + [leaf]):
        start, head = (page - 1) * size, header(page)
        cells = struct.unpack(">H", data[head + 3 : head + 5])[0]
        for i in range(cells):
            offset = struct.unpack(">H", data[head + 12 + 2 * i : head + 14 + 2 * i])[0]
            data[start + offset : start + offset + 4] = struct.pack(">I", child)
        data[head + 8 : head + 12] = struct.pack(">I", child)
    return bytes(data)


write(
    "looping-btree.apkg",
    zip_bytes([("collection.anki2", looping_btree())], zipfile.ZIP_DEFLATED),
)
