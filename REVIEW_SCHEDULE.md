# Review schedule (Ebbinghaus ladder)

Agreed design for how DayDayUP schedules reviews. The code lives in `DayDayUP/Domain/ReviewSchedule.swift`
(rules), `DayDayUP/Persistence/VocabRepository.swift` (applying answers, migration) and
`DayDayUP/Features/Today/` (the Today tab).

## The ladder

- Every word has a **step** and a **due day** (local calendar days, `yyyy-MM-dd`).
- Step 0 is **New**: the clock hasn't started. New words wait until they're first answered, so a big CSV
  import never makes hundreds of words due at once.
- Gaps after each step: **1, 2, 4, 7, 15, 30 days** (steps 1–6). Passing the 30-day review makes the word
  **remembered** (step 7); after that it comes back **every 90 days**.
- The first answer to a New word (right or wrong) starts it at step 1, due tomorrow.

## Answers

| When | Correct | Wrong |
|---|---|---|
| New word | step 1, due tomorrow | step 1, due tomorrow, Review Book |
| On or after the due day | up one step, next gap | back to step 1, due tomorrow, Review Book |
| Before the due day (early) | no change | back to step 1, due tomorrow, Review Book |

- Late reviews count normally (up one step, gap measured from the day answered).
- **Review Book**: a missed word leaves it after 2 correct reviews in a row (it reaches step 3).
- "Remembered" = step 7 and not in the Review Book.

## Today

- First tab on iPhone, first sidebar item on Mac. One row per language pair: "12 due · 5 new", Start.
- Sessions are **rounds of 20**: Review Book → lowest step → most overdue, then new words to fill the round.
  New words therefore pause while 20 or more reviews are due. "Keep going" builds the next round.
- **10 new words per pair per day** (Settings, 0–50), oldest added first. A word counts as started on the
  day it's first answered, wherever that happens.
- A round can be a **quiz** (default) or **flashcards**; in Today, "Knew it / Didn't know" counts like a
  quiz answer. Flashcards elsewhere stay practice only.
- Quizzes from a list (pair, category, folder…) still work and follow the answer rules above.

## Streak

A day counts when, after finishing a quiz or Today round, either the round had 20 or more answers, or no
reviews are left due in any pair. On a day with nothing due, learning new words therefore counts.
Days earned under the old rule (a quiz in which a word became remembered) keep counting.

## Reminders

One local notification a day at a chosen time (default 20:00), only when reviews are due on that day,
plus the due count on the app icon. Permission is asked the first time Today is opened.

## Existing data (one-time mapping, also applied to old backups)

- Never answered → New.
- Ring 1/3 → step 1; 2/3 → step 2; missed (ring 0, in the Review Book) → step 1.
- Remembered (3/3) → step 4, not remembered until it passes the 30-day review.
- Due days are spread over the next 7 days.
