# Contributing to Folio

Thanks for helping. Bug reports, translation fixes and code are all welcome.

## Reporting a problem

Open an issue with what you did, what you expected and what happened, plus
your macOS version and whether Apple Intelligence is on. Please don't attach
schoolwork, exam papers or anything personal.

## Translations

The French, Spanish, German and Chinese (Simplified) text is a draft that no
native speaker has checked. To fix a translation, open an issue or a pull
request that changes the string in `Folio/Localizable.xcstrings` (or
`FolioKit/Sources/FolioKit/Resources/Localizable.xcstrings`) and marks it
`translated`. Settings pane names must stay short: about 11 characters.

## Code

1. Build and run as described in the [README](README.md#for-developers).
2. Match the code around your change: its naming, comments and style.
3. Before sending a pull request:
   - `cd FolioKit && swift test` passes;
   - Debug and Release build with no warnings;
   - for changes to screens, render them and check the images, in English and
     German; for anything clickable, add a click check (an `act:` shot);
   - for changes to sorting, run `folio-eval` and compare with
     [Tools/TestSet/README.md](Tools/TestSet/README.md);
   - after changing any text, update the String Catalogs as described in the
     README.

## What Folio stands for

Please keep changes in line with these:

- **Private by default.** Everything runs on the Mac. Nothing is sent anywhere
  unless the student turns Claude on with their own key.
- **Never commit secrets or real papers.** No API keys anywhere in the code;
  Folio only reads a key from the keychain. Real exam papers stay out of the
  repository, including `TestSet/real/`.
- **The student's files stay theirs.** Real Finder folders, every move can be
  undone, and Folio never deletes a file.
- **Asks when unsure.** Anything Folio isn't confident about is suggested, not
  done.
- **Calendar is read only.** Folio plans around events and never changes them.
- **Helps students learn, never does their work.** No essays or assessment
  answers.
- **Calm, not gamified.** No streaks or points.
