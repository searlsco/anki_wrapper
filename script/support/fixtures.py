"""Builds the test fixtures with Anki's own library, so every file is
exactly what Anki itself exports. Run through script/generate_fixtures."""

import os
import random
import sys

from anki.collection import (
    Collection,
    DeckIdLimit,
    ExportAnkiPackageOptions,
    ImportAnkiPackageOptions,
    ImportAnkiPackageRequest,
)

upstream_dir, out_dir, work_dir = (os.path.abspath(p) for p in sys.argv[1:4])
N5 = "Open Anki JLPT N5 Deck"
N4 = "Open Anki JLPT N4 Deck"

# Hand-written for these fixtures, so they carry no third-party license.
SENTENCES = [
    ("毎朝パンを<b>食べます</b>。", "I eat bread every morning."),
    ("駅まで<b>歩いて</b>行きました。", "I walked to the station."),
    ("この本はとても<b>面白い</b>です。", "This book is very interesting."),
    ("私[わたし]は<b>学生</b>です。", "I am a student."),
]
CLOZE = "{{c1::猫}}が{{c2::好き}}です。"


def open_collection():
    return Collection(os.path.join(work_dir, "collection.anki2"))


col = open_collection()
for level in ("n5", "n4"):
    path = os.path.join(upstream_dir, f"open-anki-jlpt-{level}-deck-v0.3.0.apkg")
    col.import_anki_package(
        ImportAnkiPackageRequest(
            package_path=path, options=ImportAnkiPackageOptions(with_scheduling=True)
        )
    )

sentences_deck = col.decks.id(f"{N5}::Sentences")
basic = col.models.by_name("Basic")
for front, back in SENTENCES:
    note = col.new_note(basic)
    note["Front"], note["Back"] = front, back
    note.tags = ["sentence", "handmade"]
    col.add_note(note, sentences_deck)
cloze = col.new_note(col.models.by_name("Cloze"))
cloze["Text"] = CLOZE
col.add_note(cloze, sentences_deck)

n5 = col.decks.id_for_name(N5)
col.decks.select(n5)
random.seed(1)
for _ in range(4):
    for _ in range(200):
        card = col.sched.getCard()
        if not card:
            break
        card.start_timer()
        col.sched.answerCard(card, random.choice([1, 2, 3, 3, 3, 4]))
    seen = col.find_cards(f'deck:"{N5}" -is:new')
    col.sched.set_due_date(seen, "0")

col.sched.suspend_cards(col.find_cards(f'deck:"{N5}" is:new')[:2])

cram = col.sched.get_or_create_filtered_deck(deck_id=0)
cram.name = "Cram"
cram.config.search_terms[0].search = f'deck:"{N4}"'
cram.config.search_terms[0].limit = 5
col.sched.add_or_update_filtered_deck(cram)

# Each export closes the collection, so reopen before the next one.
col.export_collection_package(
    os.path.join(out_dir, "collection.colpkg"), include_media=True, legacy=False
)
open_collection().export_collection_package(
    os.path.join(out_dir, "collection-legacy.colpkg"), include_media=True, legacy=True
)
col = open_collection()
col.export_anki_package(
    out_path=os.path.join(out_dir, "n5-with-scheduling.apkg"),
    options=ExportAnkiPackageOptions(
        with_scheduling=True, with_deck_configs=True, with_media=True, legacy=False
    ),
    limit=DeckIdLimit(col.decks.id_for_name(N5)),
)
