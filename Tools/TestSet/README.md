# Sorting test set

`samples.json` holds 137 labelled samples: 120 schoolwork files across
Mathematics, English, Physics, Chemistry and History, and 17 that aren't
schoolwork (`_Unsorted`). They cover exam papers from several boards, notes,
worksheets, essays, handwritten-note photos, scans, French and Spanish files,
misleading file names, cross-subject cases, sensitive History topics, and
recordings and lesson videos spoken by a system voice. All text is original
sample content.

## Run it

```sh
cd FolioKit
swift run folio-testset ../Tools/TestSet/samples.json ../TestSet/generated
swift run -c release folio-eval ../TestSet/generated
```

`folio-eval` reads every file, decides what Folio would do at each auto-file
level, and writes `report.md` and `results.csv` to `TestSet/reports/<time>/`.
Nothing is moved. `--no-model` turns the on-device AI off; run `folio-eval`
with no arguments to see the other options.

## Baseline (8 Oct 2026, M1 MacBook Air, 8 GB, macOS 27)

| Setup | Top choice right | Careful: auto-filed / wrong | Clear-cut auto-filed (Careful) | Document type right | Median time |
|---|---|---|---|---|---|
| Keywords only | 94% | 0 / 0 | 0% | 36% | 0.01 s |
| General model, clues, schema in prompt | 98% | 92 / 0 | 96% | 74% | 8.7 s |
| Content tagging, fast | 99% | 94 / 0 | 96% | 42% | 1.7 s |
| **Default**: content tagging, plain retry after refusals, file name hidden when there's text | 97% | **101 / 0** | **100%** | 82% | 1.7 s |

What the testing showed, and what the defaults do about it:

- The on-device model refused 9 files (sensitive History topics and war
  poetry) when asked for a structured answer. Asking the general model the
  same question as plain text answered all 9 correctly, so refusals are retried
  that way (about 8 s each).
- Apple's content-tagging adapter answers about five times faster than the
  general model, with the same accuracy for choosing a subject.
- Both models guess document types poorly, so the type comes from words in the
  file first, then the profile's default ("Notes").
- When the AI could see a misleading file name it agreed with the keyword
  voter, which also reads the name, and a Chemistry worksheet named "physics
  worksheet" was filed wrongly. Hiding the name from the AI when a file has
  enough text keeps the two signals independent.

## Learning from past files (9 Oct 2026)

`--half odd --examples` sorts every other file after learning from the other
half's schoolwork (about 11 files per subject), as if the student had already
filed it. The report then shows the same files decided with and without the
"similar past files" voter. Both halves together:

| Setup | Careful: auto-filed / wrong | Balanced: auto-filed / wrong | Eager: wrong |
|---|---|---|---|
| AI on, without learning | 101 / 0 | 101 / 0 | 5 |
| AI on, with learning | 98 / 0 | 98 / 0 | 4 |
| AI off, without learning | 0 / 0 | 58 / 0 | 2 |
| **AI off, with learning** | **64 / 0** | **86 / 0** | 7 |

- With the AI on, keywords and the AI already agree on almost every file here,
  so learning mostly adds caution: it disagreed on three files, which Folio then
  asked about.
- With Apple Intelligence off, learning is what lets Careful file anything at
  all. That's the case it's for, along with each student's own files, which
  this test set can't imitate.
- On its own the voter picked the right subject 83% of the time, against 94% for
  keywords, and its most confident mistakes were files with almost no text. It
  now needs at least 50 characters, and one subject must lead the next by 0.10,
  which made it right 96% of the time it voted.
- With learning on, the AI and the voter once both called a guitar chord chart
  Mathematics, and Careful filed it. Agreement now only counts when the words
  in the file are part of it.

```sh
swift run -c release folio-eval ../TestSet/generated --half odd --examples
swift run -c release folio-eval ../TestSet/generated --half even --examples --no-model
```

## Recordings, videos and photos (9 Oct 2026)

Recordings are transcribed on the Mac (the first three minutes, at about 20×
real time); videos also have the text on screen read from four frames.

| Files | Top choice right | Careful: auto-filed / wrong | Median time |
|---|---|---|---|
| All 137 | 117 / 120 | 112 / 0 (clear-cut 56 / 56) | 1.4 s |
| 7 recordings, incl. one in French and a shopping list | 6 / 6 | 6 / 0 | 2.7 s |
| 6 lesson videos, incl. a cooking video | 5 / 5 | 5 / 0 | 4.8 s |
| 13 photos, text read from them | 11 / 11 | 10 / 0 | 1.5 s |
| 13 photos, shown to the AI as well | 11 / 11 | 10 / 0 | 8.4 s |

- Showing a photo to the on-device AI needs the general model (the faster
  content-tagging model can't take images) and was no more accurate when the
  text could be read, so Folio only shows it photos with under 40 characters of
  readable text. A test photo of a benzene ring, which has almost no words, was
  filed as Chemistry that way.
- Documents sort exactly as before: 101 of the original 124 at Careful.

```sh
swift run -c release folio-eval ../TestSet/generated --tag recording
swift run -c release folio-eval ../TestSet/generated --tag handwritten --images-always
```

## Curriculum packs (10 Oct 2026)

`samples-packs.json` adds 85 samples for the subject areas the curriculum
packs bring in: sciences, humanities, business and law, the arts, PE and
health, technologies, the IB core and the SACE Research Project, plus
language subjects written in their own languages and past papers named the
way exam boards name them (`0610_s23_qp_42.pdf`, `AQA-84611H-QP-JUN22.pdf`,
`1ma1-1h-que-20220520.pdf`, `ap23-frq-chemistry.pdf`). Samples are labelled
with FolioKit's subject areas (`Topics.json`), such as Biology or Legal Studies.

```sh
swift run folio-testset ../Tools/TestSet/samples-packs.json ../TestSet/generated-packs
swift run -c release folio-eval ../TestSet/generated ../TestSet/generated-packs --all-packs --group-size 7
swift run -c release folio-eval ../TestSet/generated ../TestSet/generated-packs --pack au-nsw-hsc --group-size 7
```

`--pack` sorts with a pack's own courses, each subject area standing for the
course most students take (Modern History in the HSC). `--group-size 7`
shares the areas among students of up to seven subjects, as real students
have; files that aren't schoolwork are sorted by every student.
`--all-packs` leaves the on-device AI off unless `--with-model` is given.

Keywords only, every pack:

| Pack | Courses | Top choice right | Balanced: auto-filed / wrong | Eager: wrong |
|---|---|---|---|---|
| NSW HSC | 34 | 97% | 117 / 0 | 5 |
| QCE | 35 | 96% | 122 / 0 | 6 |
| SACE | 37 | 96% | 125 / 0 | 5 |
| VCE | 37 | 96% | 122 / 0 | 6 |
| WACE | 32 | 96% | 114 / 0 | 6 |
| Cambridge International | 35 | 97% | 126 / 0 | 5 |
| IB Diploma | 32 | 96% | 116 / 0 | 5 |
| Another school | 38 | 96% | 133 / 0 | 6 |
| GCSE and A level | 35 | 97% | 120 / 0 | 4 |
| US high school and AP | 26 | 96% | 104 / 0 | 3 |

With the on-device AI (default settings):

| Pack | Top choice right | Careful: auto-filed / wrong | Clear-cut auto-filed | Median time |
|---|---|---|---|---|
| NSW HSC, 5 students | 183 / 191 | 178 / 0 | 101 / 104 | 1.6 s |
| GCSE and A level, 5 students | 191 / 195 | 186 / 0 | 110 / 110 | 1.6 s |
| Original 137 files, sample subjects | 117 / 120 | 112 / 0 | 56 / 56 | 2.0 s |

What the pack runs showed, and what changed because of them:

- Pack subjects first took other names from every language and everyday
  words such as Law, Science and Art. A physics file about Newton's laws went
  to Law, and "it" matched IT. Now those names only find a student's folder
  (`folderNames`); abbreviations such as IT and PE count only in capitals and
  not inside a line written in capitals; and the longest match wins, so
  "Hess's law" counts for Chemistry and not for a subject called Law. Keyword
  top choice rose from 85–89% to 92–95% with every area in one profile.
- With all 34 HSC courses in one profile the on-device AI chose correctly only
  88% of the time and leaned towards subjects early in its list. Careful still
  filed nothing wrongly, because the words in the file must agree. A real
  student has 6 to 8 subjects, which is what `--group-size` measures.
- A few samples labelled as not schoolwork could be schoolwork for some
  students: a guitar chord chart for Music, recipes for Food Technology, a gym
  program for PE. They carry `related` in the samples, and a profile that
  includes that subject leaves them out.

## Assessments in files (10 Oct 2026)

`assessments.json` holds 67 labelled snippets of text, in each curriculum's style:
- task sheets and exam notices;
- marking criteria and marked work;
- look-alikes such as notes with dates, past-paper guidelines, an excursion note and a library receipt.

`folio-eval --assessments` checks what Folio reads from each one. For a task sheet that's the title, kind, due date and time, weighting, total marks, exam length, and whether it's the task sheet. For marked work it's the mark. For look-alikes it checks that nothing is offered. Dates are read as if today were Saturday 10 October 2026 in Sydney.

```sh
swift run folio-eval --assessments ../Tools/TestSet/assessments.json
```

The files come in three sets:
1. **Tuning:** 37 files the reader was built against.
2. **Held out:** 16 files written after it was built.
3. **Held out 2:** 14 more files written after the first held-out set had also been used for tuning.

Each held-out set was measured once before anything was changed for it.

| Set | Task sheets found | Right date | Every detail right | Criteria and marks right | Look-alikes offered |
|---|---|---|---|---|---|
| Held out, first measure | 7 of 11 | 6 | 4 | 2 of 2 | 0 of 3 |
| Held out 2, first measure | **7 of 9** | **7** | **6** | **2 of 2** | **0 of 3** |
| All sets after fixes | 45 of 45 | 45 | 44 | 9 of 9 | 0 of 13 |

The fair figure is Held out 2's first measure. Folio found most task sheets it had never seen, gave every one it found the right date, and offered nothing for files that aren't assessments.

What it misses:
- unusual ways of saying when something is sat, such as "Performances:" or "Your interview is on" (both added after that measure);
- a heading with no word for the kind of work, such as "Visual Arts Body of Work".

Whatever it finds is only offered: the student adds it, edits it first, or dismisses it.

## Claude, with your own key (not run yet)

`--claude` asks Claude Haiku 5.5 about the files left for review at Careful,
as the app does when Claude is switched on in Settings › AI & Privacy. It
reads the API key from `ANTHROPIC_API_KEY`, checks the key with one short
question first, and prints what the run cost. Claude only sees the files left
for review, 8 of the 137 in the latest run, so that's well under 1 US cent.
`--claude-photos` also shows Claude photos with almost no readable text.

```sh
swift run -c release folio-eval ../TestSet/generated --claude
```

Claude's answer takes the place of the on-device AI's and the arbiter's rules
stay the same, so Claude can only help file a file when the words in it agree.
Otherwise it changes which subjects Folio suggests. The summary line counts
how many of the review files Claude settled and whether any were filed wrongly.

These samples are cleaner than real files, and the same person wrote both the
samples and the starter keywords, so real accuracy will be lower. Start in
Careful mode and treat corrections as the real test data.

If a report shows "The on-device AI couldn't answer" for every file, the
system briefly stopped answering; that happened once in testing. Folio now
waits once for a rate limit to clear, and the CSV's `model_note` column shows
the underlying error.

## Searching files (11 Oct 2026)

`search.json` holds 60 searches for the 120 schoolwork files in
`TestSet/generated`, each with the files a student would want to find:
42 that use the files' own words, 10 that say it differently ("how quickly a
car speeds up"), 3 in English for files in French or Spanish, and 5 about
topics none of the files cover.

```sh
swift run -c release folio-eval --search ../TestSet/generated ../Tools/TestSet/search.json
```

| Method | Right file first | Right file in the top five | Shown for topics not covered |
|---|---|---|---|
| File names, as the Library searched before | 13% | 15% | – |
| Meaning alone (the embeddings kept for sorting) | 35% | 56% | – |
| **Words in the file, rare ones weighing more, meaning added** | **84%** | **91%** | 1.0 a search |

- Meaning alone was weak: short notes, such as a photo of handwritten notes,
  came out close to almost every search, and topics no file covered still
  scored as high as real matches. So the words in each file lead, and meaning
  only adds a little. With rare words weighing more and meaning added, the
  right file came first for 7 of the 10 paraphrased searches, against 4 for
  plain word matching.
- A word matches its other endings ("differentiate", "differentiation") but
  not different words that start the same way ("different", "plantation").
  Words in no file are ignored, so "sonnet rhyme scheme" still finds the
  sonnet notes.
- Related files: for each file, 71% of its three closest files are in the
  same subject, from rare words shared and meaning.

## Flashcards (11 Oct 2026)

`cards.json` holds 13 original notes from 900 to 3,400 characters: physics,
chemistry, biology, Modern History (Nazi Germany), Macbeth, calculus,
Studies of Religion, Music, economics, Chinese grammar in Chinese, the French
Revolution in French, a long organic chemistry summary, and a past paper's
questions, which have no answers to make cards from.

```sh
swift run -c release folio-eval --cards ../Tools/TestSet/cards.json
```

| Setup | Cards kept | Dropped: answer not in the notes | Parts declined | Time, all 13 |
|---|---|---|---|---|
| First try: parts of 1,200 characters | 55 | 5 | 2 notes | 121 s |
| Plain retry after a refusal | 61 | 7 | 0 | 162 s |
| **Default: parts of 900 characters** | **83** | **5** | **0** | **194 s** |

- The model refused the Nazi Germany notes, and also Studies of Religion,
  when asked for structured cards. Asking again for plain "Q: … A: …" text
  gave good cards for both, as it did for sorting sensitive History.
- Every card's answer has to be in the notes: all its numbers, and most of its
  other words. That dropped every card the model wrote from the past paper's
  questions, and Folio also says a file that's mostly questions isn't a good
  source before it starts.
- Reading the cards, nearly all were right and useful. One French card said
  the Declaration of the Rights of Man was "abrogated" when the notes say it
  was adopted: the words were all in the notes, so the check can't catch it.
  That's why each card is shown with the line it came from, and the student
  chooses which to keep.
