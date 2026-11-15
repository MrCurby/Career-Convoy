#!/usr/bin/env python3
"""Language check: everything in this repository is written in English – code comments,
strings, logs, UI texts, docs and tool output.

Fails if a tracked text file contains German umlauts or typical German words, and prints
file:line for each hit. Runs as part of tools/test.sh, so a German comment blocks the release.

Run: python3 tests/language_check.py"""
import os
import re
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Files that are not ours to translate (game data copied from BeamNG).
SKIP = {
    "tools/zones/garage_interactions.original.json",
    "client/levels/west_coast_usa/main/MissionGroup/career_garage/garage_interactions/items.level.json",
    "tests/language_check.py",  # contains the word list below
}
TEXT_EXT = (".lua", ".js", ".html", ".css", ".json", ".py", ".sh", ".yml", ".yaml", ".md", ".txt", ".gitignore")

UMLAUTS = re.compile(r"[äöüÄÖÜß]")
# Words that are common in German and (practically) never appear in English text or code.
GERMAN_WORDS = re.compile(r"\b(" + "|".join([
    "und", "nicht", "wird", "werden", "wurde", "wenn", "oder", "aber", "auch", "noch", "nur",
    "beim", "schon", "sonst", "damit", "weil", "dann", "sind", "kein", "keine", "einen", "eine",
    "einem", "einer", "dem", "des", "ist", "zum", "zur", "bei", "nach", "vom", "alle", "allen",
    "wieder", "gibt", "hier", "jetzt", "danach", "dafür", "dass", "sich", "ohne", "zwischen",
    "Spieler", "Fahrzeug", "Fahrzeuge", "Einstellung", "Einstellungen", "Uhrzeit", "Karriere",
    "Spielstand", "Tankstelle", "Lieferung", "gesetzt", "geschickt", "gespeichert", "bleibt",
    "Fehler", "Hinweis", "Ablauf", "Aufruf", "Ausführen",
]) + r")\b")


def tracked_files():
    out = subprocess.run(["git", "ls-files"], cwd=ROOT, capture_output=True, text=True, check=True).stdout
    return [f for f in out.splitlines() if f.endswith(TEXT_EXT) and f not in SKIP]


def main():
    hits = []
    for f in tracked_files():
        path = os.path.join(ROOT, f)
        if not os.path.exists(path):
            continue
        with open(path, encoding="utf-8", errors="replace") as fh:
            for n, line in enumerate(fh, 1):
                m = UMLAUTS.search(line) or GERMAN_WORDS.search(line)
                if m:
                    hits.append(f"{f}:{n}: '{m.group(0)}': {line.strip()[:100]}")
    for h in hits:
        print("GERMAN TEXT", h)
    print(f"Language check: {len(hits)} German text(s) found" if hits else "Language check: ok (English only)")
    sys.exit(1 if hits else 0)


main()
