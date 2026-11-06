# Similar words, background web search and reference-only lists

Agreed design. Code: `DayDayUP/Dictionary/` (lookup, dictionaries, sources), `DayDayUP/Features/Library/AddWord.swift`
(the Add sheet), `DayDayUP/Persistence/` (reference-only categories).

## Looking a word up

- **Exact match in the offline dictionary**: its meanings show at once. No web search runs. A
  "More meanings online" button at the bottom runs one.
- **No exact match**: similar words from the offline dictionary show at once. Below them, a
  "Searching online…" section fills in as the web answers arrive.
  - Tapping a similar word cancels the web search and looks that word up.
  - Every enabled web source is asked at the same time (Wiktionary, Wikipedia, Apple Translate,
    MyMemory). Each source's meanings appear as their own group, in the order set in Settings.
  - A source that hasn't answered after 10 seconds shows "No answer" (a late answer still appears).
  - The search starts once the sheet is on screen, because Apple's translator may need to show its
    own sheet (for example to download a language).
  - Web meanings show their source. When similar words were found (so the typed word may be a
    misspelling), the section notes `for "recieve" as typed`.
  - Apple Translate and MyMemory meanings carry a "machine translation" tag.
- The editor's "Look up more meanings" uses the same sheet.

## Offline dictionary (ECDICT)

- Lookups already use SQLite's index on the word column (a sorted B-tree, so O(log n)); no sorting
  is needed at run time. Measured on a Mac with the full dictionary: under 0.3 ms for an exact
  lookup, 7–42 ms for similar words.
- ECDICT now keeps every single word (about 400k, including technical, medical and legal terms)
  and, as before, phrases that are exam-tagged or among the 60k most common. ECDICT has no frequency
  rank for most phrases, so only about 900 are kept (common ones like "give up" aren't). About 90 MB
  on the device. The download is the same 66 MB file.
- A dictionary built by an older version shows **Update** in Settings → Dictionaries. Saved words
  aren't touched by an update.

## Similar words (English)

1. Words that start with what was typed.
2. Spelling neighbours: same first letter, length within 2, at most 1 mistake (words of 4 letters
   or fewer) or 2 mistakes. Two swapped letters ("recieve") count as one mistake.
3. Sounds-like matches: each word has a sound key (fonetic → phonetic, kat → cat, nolij → knowledge),
   stored in the dictionary when it's built (`Dictionary/SoundKey.swift`, mirrored in
   `Tools/build_dictionaries.py`). Any first letter. A short key (2 sounds, like KT) also needs a
   near spelling; a longer key can bring in up to 3 common words spelled quite differently.

Common words (frequency rank ≤ 60k) rank first; rare words are only shown when no common word
matches. Within a group: fewest mistakes first, then the most common.

Chinese and Japanese keep today's similar words (words that start with what was typed).

## Reference-only categories (technical terms, tool names)

- Any category can be switched to **Reference only** (category menu, and when creating one).
  Its row shows a book icon.
- Its words use the same Add sheet and lookups, and show in lists and search.
- They never appear in Today, quizzes, flashcards, the Review Book, due counts, the icon badge,
  reminders, the Progress ladder, or remembered counts.
- Switching a category to Reference only (or moving a word into one) pauses its progress. Switching
  back resumes it; anything overdue comes up in Today.
- A pair whose words are all reference-only is hidden in Today and still shows in Library.
- Backups keep the setting.

## Wikipedia source

- New web source, on by default, can be turned off in Settings → Dictionaries → Advanced.
- Uses the Wikipedia of the word's language. Gives the one-line description as the explanation,
  and the linked article title in the pair's other language as the translation (Idempotence → 幂等).
  When there's no linked article, or its title is just the same name, the description is
  machine-translated and marked approximate.
- Disambiguation pages are skipped.
