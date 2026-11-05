#!/usr/bin/env python3
"""
Build DayDayUP's offline dictionaries (the app can also do this itself on import).

Produces three SQLite files that share one schema:

    ecdict.sqlite   English  -> Chinese   (ECDICT, MIT)
    cedict.sqlite   Chinese  -> English   (CC-CEDICT, CC BY-SA 3.0)
    jmdict.sqlite   Japanese -> English   (JMdict, CC BY-SA 4.0, EDRDG)

Schema
------
    meta(key TEXT PRIMARY KEY, value TEXT)
    entries(id INTEGER PRIMARY KEY, headword TEXT, reading TEXT,
            senses TEXT,   -- JSON: [{"pos": "n.", "en": "...", "zh": "..."}]
            rank INTEGER)  -- lower = more common
    forms(form TEXT, entry_id INTEGER)   -- every lookup key for an entry

Usage
-----
    python3 build_dictionaries.py ecdict --input ecdict.csv
    python3 build_dictionaries.py cedict --input cedict_1_0_ts_utf-8_mdbg.txt.gz
    python3 build_dictionaries.py jmdict --input JMdict_e.gz
    python3 build_dictionaries.py all --input-dir ./sources

Source downloads (do this yourself, then point --input at the file):
    ECDICT    https://github.com/skywind3000/ECDICT  (ecdict.csv)
    CC-CEDICT https://www.mdbg.net/chinese/dictionary?page=cc-cedict
    JMdict    https://www.edrdg.org/jmdict/edict_doc.html  (JMdict_e.gz)

Upload the resulting .sqlite files somewhere the app can download them
(for example a GitHub release) and paste that folder URL into
Settings -> Dictionaries, or import them directly from the Files app.
"""

import argparse
import csv
import gzip
import json
import os
import re
import sqlite3
import sys
import xml.etree.ElementTree as ET

csv.field_size_limit(sys.maxsize)

SCHEMA = """
DROP TABLE IF EXISTS meta;
DROP TABLE IF EXISTS entries;
DROP TABLE IF EXISTS forms;
CREATE TABLE meta(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE entries(id INTEGER PRIMARY KEY, headword TEXT, reading TEXT, senses TEXT, rank INTEGER);
CREATE TABLE forms(form TEXT, entry_id INTEGER);
"""

INDEXES = """
CREATE INDEX idx_forms_form ON forms(form);
CREATE INDEX idx_entries_rank ON entries(rank);
"""


def clean(text):
    """Sense fields must never contain ';' because the app's CSV export joins senses with '; '."""
    text = (text or "").replace(";", ",").replace("；", "，")
    return re.sub(r"\s+", " ", text).strip(" ,，")


def open_text(path):
    if path.endswith(".gz"):
        return gzip.open(path, "rt", encoding="utf-8")
    return open(path, "r", encoding="utf-8")


class Writer:
    def __init__(self, out_path, meta):
        if os.path.exists(out_path):
            os.remove(out_path)
        self.db = sqlite3.connect(out_path)
        self.db.executescript(SCHEMA)
        self.db.executemany("INSERT INTO meta VALUES (?, ?)", list(meta.items()))
        self.next_id = 1
        self.count = 0

    def add(self, headword, reading, senses, rank, forms):
        senses = [s for s in senses if s.get("en") or s.get("zh")]
        if not headword or not senses:
            return
        eid = self.next_id
        self.next_id += 1
        self.db.execute(
            "INSERT INTO entries VALUES (?, ?, ?, ?, ?)",
            (eid, headword, reading or "", json.dumps(senses, ensure_ascii=False), rank),
        )
        for form in sorted(set(f for f in forms if f)):
            self.db.execute("INSERT INTO forms VALUES (?, ?)", (form, eid))
        self.count += 1

    def close(self):
        self.db.execute("INSERT OR REPLACE INTO meta VALUES ('entries', ?)", (str(self.count),))
        self.db.executescript(INDEXES)
        self.db.commit()
        self.db.execute("VACUUM")
        self.db.close()
        return self.count


# ---------------------------------------------------------------- ECDICT

POS_RE = re.compile(r"^\s*([a-z]{1,6}\.)\s*(.*)$")


def split_pos_lines(field):
    lines = []
    for raw in (field or "").replace("\\n", "\n").split("\n"):
        raw = raw.strip()
        if not raw:
            continue
        m = POS_RE.match(raw)
        if m:
            lines.append((m.group(1), m.group(2).strip()))
        else:
            lines.append(("", raw))
    return lines


def ecdict_rank(row):
    ranks = []
    for k in ("frq", "bnc"):
        v = (row.get(k) or "").strip()
        if v.isdigit() and int(v) > 0:
            ranks.append(int(v))
    return min(ranks) if ranks else 999999


def keep_ecdict_row(row, max_rank):
    word = row.get("word", "")
    if not word or len(word) > 40:
        return False
    if not (row.get("translation") or "").strip():
        return False
    if (row.get("tag") or "").strip() or (row.get("oxford") or "") == "1":
        return True
    if (row.get("collins") or "0") not in ("", "0"):
        return True
    return ecdict_rank(row) <= max_rank


def build_ecdict(path, out_path, max_rank):
    w = Writer(out_path, {"id": "ecdict", "source": "en", "title": "ECDICT", "license": "MIT"})
    with open_text(path) as f:
        for row in csv.DictReader(f):
            if not keep_ecdict_row(row, max_rank):
                continue
            definitions = split_pos_lines(row.get("definition"))
            senses = []
            for pos, zh_line in split_pos_lines(row.get("translation")):
                # Pair each Chinese line with the first unused English definition of the same POS.
                en = ""
                for i, (dpos, dtext) in enumerate(definitions):
                    if dpos == pos:
                        en = dtext
                        definitions.pop(i)
                        break
                for zh in re.split(r"[;；]", zh_line):
                    zh = clean(zh)
                    if zh:
                        senses.append({"pos": pos, "en": clean(en), "zh": zh})
            if not senses:
                continue
            word = row["word"].strip()
            phonetic = (row.get("phonetic") or "").strip()
            w.add(word, f"/{phonetic}/" if phonetic else "", senses, ecdict_rank(row), [word.lower()])
    return w.close()


# ---------------------------------------------------------------- CC-CEDICT

CEDICT_RE = re.compile(r"^(\S+)\s+(\S+)\s+\[([^\]]*)\]\s+/(.*)/\s*$")
TONE_MARKS = {
    "a": "āáǎàa", "e": "ēéěèe", "i": "īíǐìi", "o": "ōóǒòo", "u": "ūúǔùu", "ü": "ǖǘǚǜü",
}


def numbered_to_marked(syllable):
    s = syllable.replace("u:", "ü").replace("v", "ü")
    m = re.match(r"^([a-zü]+)([1-5])$", s, re.IGNORECASE)
    if not m:
        return s
    base, tone = m.group(1), int(m.group(2))
    if tone == 5:
        return base
    lower = base.lower()
    if "a" in lower:
        idx = lower.index("a")
    elif "e" in lower:
        idx = lower.index("e")
    elif "ou" in lower:
        idx = lower.index("o")
    else:
        idx = max(i for i, ch in enumerate(lower) if ch in "aeiouü") if any(ch in "aeiouü" for ch in lower) else -1
    if idx < 0:
        return base
    ch = lower[idx]
    marked = TONE_MARKS[ch][tone - 1]
    if base[idx].isupper():
        marked = marked.upper()
    return base[:idx] + marked + base[idx + 1:]


def pinyin_marks(text):
    return " ".join(numbered_to_marked(p) for p in text.split())


def build_cedict(path, out_path):
    w = Writer(out_path, {"id": "cedict", "source": "zh", "title": "CC-CEDICT", "license": "CC BY-SA 3.0"})
    with open_text(path) as f:
        for line_no, line in enumerate(f):
            if line.startswith("#"):
                continue
            m = CEDICT_RE.match(line.strip())
            if not m:
                continue
            trad, simp, pinyin, glosses = m.groups()
            senses = []
            for g in glosses.split("/"):
                g = g.strip()
                if not g or g.startswith("CL:"):
                    continue
                senses.append({"pos": "", "en": clean(g), "zh": ""})
            # Shorter, earlier headwords are usually more common; CC-CEDICT has no frequency data.
            rank = len(simp) * 100000 + line_no
            w.add(simp, pinyin_marks(pinyin), senses, rank, [simp, trad])
    return w.close()


# ---------------------------------------------------------------- JMdict

def jm_pos(pos_text):
    p = (pos_text or "").lower()
    if p.startswith("noun") or "noun (" in p:
        return "n."
    if "verb" in p and "adverb" not in p:
        return "v."
    if "adverb" in p:
        return "adv."
    if "adjective" in p or "adjectival" in p or "pre-noun" in p:
        return "adj."
    if "pronoun" in p:
        return "pron."
    if "conjunction" in p:
        return "conj."
    if "interjection" in p:
        return "int."
    if "particle" in p:
        return "part."
    if "counter" in p:
        return "ctr."
    if "expression" in p:
        return "exp."
    return ""


def jm_rank(priorities):
    if not priorities:
        return 900000
    best = 500000
    for p in priorities:
        if p.startswith("nf") and p[2:].isdigit():
            best = min(best, int(p[2:]) * 500)
        elif p in ("news1", "ichi1", "spec1", "gai1"):
            best = min(best, 2000)
        elif p in ("news2", "ichi2", "spec2", "gai2"):
            best = min(best, 30000)
    return best


def build_jmdict(path, out_path):
    w = Writer(out_path, {"id": "jmdict", "source": "ja", "title": "JMdict", "license": "CC BY-SA 4.0 (EDRDG)"})
    opener = gzip.open if path.endswith(".gz") else open
    with opener(path, "rb") as f:
        for _, elem in ET.iterparse(f, events=("end",)):
            if elem.tag != "entry":
                continue
            kebs = [k.text for k in elem.iterfind("k_ele/keb") if k.text]
            rebs = [r.text for r in elem.iterfind("r_ele/reb") if r.text]
            pri = [p.text for p in elem.iterfind("k_ele/ke_pri") if p.text] + \
                  [p.text for p in elem.iterfind("r_ele/re_pri") if p.text]
            senses = []
            last_pos = ""
            for sense in elem.iterfind("sense"):
                pos_list = [p.text for p in sense.iterfind("pos") if p.text]
                pos = jm_pos(pos_list[0]) if pos_list else last_pos
                last_pos = pos
                glosses = [g.text for g in sense.iterfind("gloss") if g.text]
                if glosses:
                    senses.append({"pos": pos, "en": clean(", ".join(glosses[:3])), "zh": ""})
            head = kebs[0] if kebs else (rebs[0] if rebs else "")
            w.add(head, rebs[0] if rebs else "", senses, jm_rank(pri), kebs + rebs)
            elem.clear()
    return w.close()


# ---------------------------------------------------------------- CLI

def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("which", choices=["ecdict", "cedict", "jmdict", "all"])
    ap.add_argument("--input", help="source file for a single dictionary")
    ap.add_argument("--input-dir", help="folder holding ecdict.csv, cedict_1_0_ts_utf-8_mdbg.txt.gz, JMdict_e.gz")
    ap.add_argument("--out-dir", default="build")
    ap.add_argument("--ecdict-max-rank", type=int, default=60000,
                    help="keep untagged ECDICT words only if their frequency rank is at most this (trims size)")
    args = ap.parse_args()
    os.makedirs(args.out_dir, exist_ok=True)

    jobs = {
        "ecdict": ("ecdict.csv", lambda i, o: build_ecdict(i, o, args.ecdict_max_rank)),
        "cedict": ("cedict_1_0_ts_utf-8_mdbg.txt.gz", build_cedict),
        "jmdict": ("JMdict_e.gz", build_jmdict),
    }
    targets = list(jobs) if args.which == "all" else [args.which]
    for name in targets:
        default_file, fn = jobs[name]
        src = args.input if (args.input and args.which != "all") else os.path.join(args.input_dir or ".", default_file)
        if not os.path.exists(src):
            sys.exit(f"Missing source for {name}: {src}")
        out = os.path.join(args.out_dir, f"{name}.sqlite")
        n = fn(src, out)
        print(f"{name}: {n} entries -> {out} ({os.path.getsize(out) / 1e6:.1f} MB)")


if __name__ == "__main__":
    main()
