# DayDayUP

![DayDayUP logo](Tools/logo/preview.png)

*天天向上: a little better every day.* (Formerly VocaQuest.)

A playful personal vocabulary app for iPhone (iOS 18+) and Mac (macOS 12+), built with SwiftUI and Core Data. It covers English → Chinese, Chinese → English and Japanese → Chinese, with offline dictionaries, multi-meaning lookups, built-in pronunciation, daily reviews on the Ebbinghaus forgetting curve, flashcards, quizzes, a Review Book, reminders, streaks and achievements.

## 1. Build the app

You need a Mac with a current Xcode (the app targets macOS 12, but Xcode itself needs a recent macOS).

```bash
brew install xcodegen      # once
xcodegen                   # creates DayDayUP.xcodeproj from project.yml
open DayDayUP.xcodeproj
```

The team ID and bundle identifiers are set in `project.yml`. Run the `DayDayUP-iOS` or `DayDayUP-macOS` scheme on your iPhone or Mac. The bundle identifiers deliberately keep the old name (`…vocaquest…`): changing them would start the app with an empty library.

**Without XcodeGen:** create a new Multiplatform App project in Xcode named DayDayUP, delete its template Swift files, drag the `DayDayUP/` folder in, set the deployment targets to iOS 18.0 and macOS 12.0, add `-weak_framework Translation` to the macOS target's Other Linker Flags, and enable App Sandbox with Outgoing Connections and User Selected Files (Read/Write) for macOS.

> This code was written without access to a Swift compiler, so expect a few compile errors to fix on first build. They should be small (a type annotation here, an API label there).

## 2. Install the dictionaries

The app looks words up in three offline dictionaries. In **Settings → Dictionaries**, tap **Download**: the app fetches the file from its official source (the links are built into the app, in `DictionaryID.sourceURL`), converts it on the device and installs it. Each takes a few seconds on a good connection:

| Dictionary | Built-in download | Size | Entries |
|---|---|---|---|
| English → Chinese | `https://raw.githubusercontent.com/skywind3000/ECDICT/master/ecdict.csv` | 66 MB | ~59k |
| Chinese → English | `https://www.mdbg.net/chinese/export/cedict/cedict_1_0_ts_utf-8_mdbg.txt.gz` | 4 MB | ~125k |
| Japanese → English | `https://www.edrdg.org/pub/Nihongo/JMdict_e.gz` | 11 MB | ~219k |

ECDICT is trimmed to tagged (exam/Oxford/Collins) and common words, about 59k entries and 12 MB.

**Import** takes the same files if you already have them (plain or `.gz`; `.zip` archives need unzipping first), and recognizes which dictionary a file is whichever row's button you used. It also takes `.sqlite` files prebuilt with Python (`python3 Tools/build_dictionaries.py all --input-dir ./sources --out-dir ./build`, same rules as the app). You can also add built `.sqlite` files to the app target's resources.

Licences: ECDICT (MIT), CC-CEDICT (CC BY-SA 3.0), JMdict (CC BY-SA 4.0, EDRDG). Credits appear in Settings → About.

## 3. How the agreed rules map to code

| Rule | Where |
|---|---|
| Language pair → category → folder → words; soft deletes; moves and merges; duplicate checks | `Persistence/VocabRepository.swift` |
| Model that's ready for iCloud sync | `Persistence/ManagedModel.swift`, `Sync/SyncService.swift`, `CLOUD_SYNC_TODO.md` |
| Each sense = translation, part of speech, English explanation; first = primary | `Domain/StudyModels.swift` (`Sense`) |
| Review ladder (1, 2, 4, 7, 15, 30 days, then every 90), early answers, misses and the Review Book; see `REVIEW_SCHEDULE.md` | `Domain/ReviewSchedule.swift` |
| Today rounds of 20, new words per day | `Domain/TodayPlanner.swift`, `Features/Today/TodayView.swift` |
| Daily reminder and app-icon badge | `Domain/ReminderService.swift` |
| Screens: Today · Library · Settings on iPhone; Today · Recent · pairs · Recently Deleted in the Mac sidebar; see `SIMPLIFICATION_PLAN.md` | `Features/Root/RootView.swift` |
| One Study sheet (quiz or flashcards) for any list | `Features/Study/Flashcards.swift` (`StudySheet`) |
| Progress page: 30-day activity chart, words per ladder step, streak, achievements | `Features/Progress/ProgressPage.swift` |
| Recently opened lists, hidden empty language pairs, dismissed dictionary banners (per device) | `Domain/LibraryState.swift` |
| One-time move of old 3-ring progress onto the ladder (store upgrade + mapping) | `Persistence/VocabRepository.swift` (`migrateIfNeeded`, `mapLegacyProgressIfNeeded`) |
| Lookup: offline dictionary first, then every web source at once in the Add sheet; pivoting through English for Japanese → Chinese; see `LOOKUP_AND_REFERENCE.md` | `Dictionary/LookupService.swift`, `Features/Library/AddWord.swift` |
| Similar words: spelling neighbours (swapped letters count once), sounds-like keys, common words first | `Dictionary/LocalDictionary.swift`, `Dictionary/SoundKey.swift` |
| Reference-only categories (kept, never reviewed) | `Persistence/VocabRepository.swift` (`reviewable`), `Features/Root/RootView.swift` |
| Web sources: Wiktionary, Wikipedia (terms and names), Apple Translate (iOS 18 / macOS 15), MyMemory | `Dictionary/OnlineSources.swift` |
| Quiz priority, primary-sense answers, same-scope/same-POS distractors with widening fallback | `Domain/QuizEngine.swift` |
| Streak day = a round of 20 finished, or today's reviews cleared; achievements | `Domain/Gamification.swift` |
| Full backup and per-table CSV with merge/skip/replace | `ImportExport/ImportExport.swift` |
| In-app dictionary import (ECDICT CSV, CC-CEDICT, JMdict, .gz) | `Dictionary/DictionaryBuilder.swift` |
| Pronunciation: Wiktionary recordings → Azure neural voice → Apple voice, cached | `Speech/SpeechService.swift` |
| Playful design system (chunky buttons, progress coin, confetti) | `DesignSystem/DesignSystem.swift` |

## 4. Known limitations

- **Chinese polyphones.** With an Azure key, Chinese words are sent with their dictionary pinyin so 行 (xíng/háng) is read correctly. Apple's offline voice still reads from the characters and may pick the other reading.
- **Japanese → Chinese meanings are approximate.** They come from JMdict's English glosses translated into Chinese, and are labelled "approximate" so you can edit them.
- **Chinese → English entries have no part of speech**, because CC-CEDICT doesn't include it. You can type one in.
- **macOS 12–14** can't use Apple's on-device translator, so Japanese → Chinese lookups there need internet (MyMemory, with a daily limit).

## 5. To be implemented

iCloud sync, custom backend sync, semantic-similarity distractors, reverse quiz mode, real-person recordings for Chinese and Japanese, Cantonese, Traditional Chinese tables, a mascot and a streak freeze.

## 6. Pronunciation

Settings → Pronunciation:

1. **Human recordings (English).** Native-speaker recordings from Wiktionary/Wikimedia Commons (CC BY-SA), in your chosen accent (US by default, or UK) when one exists.
2. **Azure neural voices.** Used for Chinese, Japanese and English words without a recording. Create a free Speech resource at https://portal.azure.com (Free F0 tier: 500k characters a month), then paste its key and region (for example `eastus`). The key is stored in the Keychain. Default voices: en-US Jenny, en-GB Sonia, zh-CN Xiaoxiao, ja-JP Nanami.
3. **Apple's voice.** Used offline, or when no key is set.

Audio is cached after the first play.

## 7. Data locations after the rename

App data still lives under `Application Support/VocaQuest/` and the Core Data store is still named `VocaQuest`, so nothing moved. Backups keep the `vocaquest-backup` format, so old backups restore. The app icon is generated by `swift Tools/logo/make_logo.swift Tools/logo DayDayUP/Assets.xcassets/AppIcon.appiconset` (vector master: `Tools/logo/logo.svg`).
