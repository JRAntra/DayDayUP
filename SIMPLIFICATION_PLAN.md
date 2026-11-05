# Simplification, Progress page and Recent lists

Agreed design (keeps every existing feature; things move, merge or lose a duplicate).

## Navigation
- iPhone tabs: **Today · Library · Settings** (Review Book tab removed).
- Today has a "Struggling words (n)" row that opens the Review Book list. Every list's status menu has
  "In Review Book".
- Mac sidebar: Today · Recent · language pairs · Recently Deleted. Review Book and Achievements move into Today.

## Library
- Shows Recent (last 5 lists) and the language pairs only; the streak card moves to Today.
- Pair screen: "All words", then categories with their folders as collapsible rows. Tapping a category
  opens its list. Unfiled shows only when a category has folders. Remembered counts on rows.

## Word lists
- One header row: search · status menu (All, Due today, In Review Book, Not remembered, Remembered) · filter button.
- No summary bar; no "Show filters" in More.
- Toolbar: **Study** (one sheet: Quiz / Flashcards, number of questions, include remembered, speak words aloud)
  and **More** (CSV export / import).

## Today
- Streak card (opens Progress), Quiz/Flashcards picker plus a speak-aloud switch, struggling words row, pairs.

## Review Book buttons
- Kept in the word editor, the iPhone swipe and the Mac toolbar; removed from flashcards.

## Dictionary banner
- "Download (size)" downloads in place with progress; "Not now" hides it for that pair.

## Settings (4 pages)
- Daily review · Dictionaries (Advanced: lookup order, MyMemory email) · Pronunciation (accent, speed;
  Advanced: Azure, offline voices, saved audio) · Your data (backup, Recently Deleted on iPhone, About).
- "iCloud sync — Coming soon" removed. Speak-automatically switches live in Study and Today.

## Progress page (replaces Achievements, opened from the streak card)
- Pair filter (pairs with words). Activity: reviews per day for 30 days, correct vs missed bars, words-added
  line (answers are counted from this version on). Ladder: words per step (New, 1–6, Remembered).
- Streak and achievements below. Drawn with SwiftUI shapes (Swift Charts needs macOS 13).

## Recent lists
- Last 5 opened lists (category, folder, Unfiled, All words, Review Book), newest first, with remembered count.
- Per device, not in backups; deleted lists drop out.

## Empty pairs
- Today, Library and the Mac sidebar hide pairs with no words. "Add a language pair" also lists hidden
  empty pairs to open. With no words at all, Today and Library show an "Add your first word" message.
