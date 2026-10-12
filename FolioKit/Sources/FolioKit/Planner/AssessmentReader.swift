import Foundation

/// Reads what a file says about an assessment: a task sheet's title, kind,
/// weighting, marks and date; whether it's marking criteria; or the mark on
/// work handed back. Whatever it finds is offered to the student to confirm,
/// never added on its own.
public enum AssessmentReader {
    /// An assessment a file sets, or a date it gives for one.
    public struct Found: Hashable, Sendable {
        public var title: String
        public var kind: Assessment.Kind
        /// When it's due, or when the exam or test starts.
        public var due: Date
        public var lengthMinutes: Int?
        public var weighting: Double?
        public var totalMarks: Double?
        /// The words the date was found in, such as "Due date: Friday 14 March".
        public var context: String

        public init(title: String, kind: Assessment.Kind, due: Date, lengthMinutes: Int? = nil, weighting: Double? = nil, totalMarks: Double? = nil, context: String = "") {
            self.title = title
            self.kind = kind
            self.due = due
            self.lengthMinutes = lengthMinutes
            self.weighting = weighting
            self.totalMarks = totalMarks
            self.context = context
        }
    }

    /// Everything Folio could tell about a file and assessments.
    public struct Reading: Hashable, Sendable {
        public var assessment: Found?
        /// What the file is to an assessment, when Folio can tell.
        public var role: FileRole?
        /// The mark on work handed back.
        public var mark: Assessment.Mark?
        /// An open assessment the file names, offered as a link.
        public var mentioned: Assessment.ID?

        public init(assessment: Found? = nil, role: FileRole? = nil, mark: Assessment.Mark? = nil, mentioned: Assessment.ID? = nil) {
            self.assessment = assessment
            self.role = role
            self.mark = mark
            self.mentioned = mentioned
        }

        public var isEmpty: Bool {
            assessment == nil && role == nil && mark == nil && mentioned == nil
        }
    }

    /// Reads a file. `open` are the student's open assessments in the subject
    /// the file went to, so a file that names one can be linked to it.
    /// Returns `nil` when the file says nothing about assessments.
    public static func read(_ evidence: Evidence, facets: Facets = Facets(), open: [Assessment] = [], now: Date = .now, calendar: Calendar = .current) -> Reading? {
        // Past papers and their marking guidelines are practice, not the student's own assessments.
        if facets.exam != nil && facets.year != nil {
            return nil
        }
        let text = evidence.text
        let lower = TermMatcher.normalize(text)
        let head = String(lower.prefix(700))
        let name = TermMatcher.normalize([evidence.title, evidence.readableFileName].compactMap { $0 }.joined(separator: "\n"))

        var reading = Reading()
        let setsTask = taskWords.contains { TermMatcher.contains($0, in: head) || TermMatcher.contains($0, in: name) }
            || weighting(in: head) != nil
        let kind = kind(in: name + "\n" + head)
        let sitting = kind == .exam || kind == .test
        // A kind named in the heading counts even without other signs of a task sheet.
        let heading = TermMatcher.normalize(evidence.text.components(separatedBy: .newlines).prefix(2).joined(separator: "\n"))
        let namedInHeading = kind != .task && self.kind(in: name + "\n" + heading) == kind

        if let found = DueDateFinder.dueDate(in: text, now: now, calendar: calendar, includesSittings: setsTask || sitting || namedInHeading) {
            let weighting = weighting(in: lower)
            let length = lengthMinutes(in: lower)
            var foundKind = setsTask || weighting != nil || sitting || namedInHeading ? kind : .task
            // A task done in a set time or on a set day, such as an in-class essay
            // or a SAC, is sat like a test.
            if foundKind == .task && setsTask && (length != nil || found.isSitting) {
                foundKind = .test
            }
            reading.assessment = Found(
                title: title(in: evidence),
                kind: foundKind,
                due: found.date,
                lengthMinutes: foundKind == .exam || foundKind == .test ? length : nil,
                weighting: weighting,
                totalMarks: totalMarks(in: lower),
                context: found.context
            )
            if setsTask || weighting != nil {
                reading.role = .taskSheet
            }
        }

        if reading.role == nil {
            if criteriaWords.contains(where: { TermMatcher.contains($0, in: head) || TermMatcher.contains($0, in: name) }) {
                reading.role = .criteria
            } else if let mark = mark(in: lower), returnedWords.contains(where: { TermMatcher.contains($0, in: lower) }) {
                reading.role = .returned
                reading.mark = mark
            }
        }

        let named = open.filter { assessment in
            guard isDistinctive(assessment.title) else { return false }
            let title = TermMatcher.normalize(assessment.title)
            return TermMatcher.contains(title, in: name) || TermMatcher.contains(title, in: head)
        }
        if named.count == 1 {
            reading.mentioned = named[0].id
            if reading.role == nil {
                reading.role = .resource
            }
        }
        return reading.isEmpty ? nil : reading
    }

    // MARK: What kind of assessment

    /// Words that say a file sets an assessment, across the curriculum packs.
    static let taskWords = [
        "assessment notification", "assessment task", "notification of assessment", "task notification",
        "assessment brief", "assignment brief", "task sheet", "assignment", "outcomes assessed",
        "school-assessed coursework", "school assessed coursework", "SAC", "internal assessment",
        "non-exam assessment", "NEA", "coursework", "research project", "depth study",
        "investigation", "unit outline", "assessment schedule", "weighting",
    ].map(TermMatcher.normalize)

    static let criteriaWords = ["marking criteria", "marking guidelines", "marking rubric", "rubric", "assessment criteria", "success criteria"].map(TermMatcher.normalize)

    static let returnedWords = ["feedback", "teacher comment", "teacher comments", "comments", "your mark", "mark awarded", "result", "grade"].map(TermMatcher.normalize)

    /// The first kind named near the top, the file name and title counting
    /// first. Of two words at the same place, the longer wins, so a
    /// "practical test" is a test. Names of long tasks count too, so a depth
    /// study that asks for a practical investigation is still a task.
    static func kind(in text: String) -> Assessment.Kind {
        let kinds: [(Assessment.Kind, [String])] = [
            (.task, ["depth study", "research project", "research task", "major work", "major project", "assignment", "portfolio", "investigation"]),
            (.exam, ["examination", "exam", "trial", "half-yearly", "half yearly", "yearly", "mid-year", "end of year", "end-of-year", "final exam", "mock", "practical exam", "practical examination", "oral exam", "oral examination"]),
            (.test, ["test", "quiz", "in-class", "in class", "in-class task", "in class task", "topic test", "class test", "practical test"]),
            (.presentation, ["presentation", "oral", "speech", "viva", "seminar", "multimodal", "performance", "interview"]),
            (.practical, ["practical", "prac"]),
        ]
        var best: (kind: Assessment.Kind, range: Range<String.Index>)?
        for (kind, words) in kinds {
            for word in words {
                guard let range = TermMatcher.ranges(of: word, in: text).first else { continue }
                guard let current = best else {
                    best = (kind, range)
                    continue
                }
                if range.lowerBound < current.range.lowerBound
                    || (range.lowerBound == current.range.lowerBound && range.upperBound > current.range.upperBound) {
                    best = (kind, range)
                }
            }
        }
        return best?.kind ?? .task
    }

    // MARK: Details

    /// A task's title: a labelled one, a "Task 2: …" line near the top, the
    /// document's own title, or else the file name.
    static func title(in evidence: Evidence) -> String {
        let lines = evidence.text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        for line in lines.prefix(30) {
            if let match = line.firstMatch(of: /(?i)^(?:task|assessment|assignment|project)\s+(?:title|name)\s*[:\-–]\s*(.{3,80})$/) {
                return tidy(String(match.output.1))
            }
        }
        for line in lines.prefix(15) where line.count <= 90 {
            let lower = TermMatcher.normalize(line)
            if lower == "assessment notification" || lower == "assessment task notification" || lower == "notification of assessment" {
                continue
            }
            // "Task 2: Depth Study", or "Unit 3 SAC 2: Data analysis" with a short lead-in.
            if line.contains(/(?i)^(?:[\w ]{0,20}\s)?(?:assessment\s+)?(?:task|assignment|project|investigation|SAC|IA|NEA)\s*(?:\d+|[A-Z])\b/) {
                return tidy(line)
            }
        }
        // Otherwise a heading near the top that names the work, such as "Theory of Knowledge essay".
        for line in lines.prefix(8) where line.count <= 90 {
            let lower = TermMatcher.normalize(line)
            guard !DueDateFinder.cues.contains(where: { TermMatcher.contains($0, in: lower) }),
                  !lower.contains("date"), !lower.hasPrefix("assessment notification")
            else { continue }
            if headingWords.contains(where: { TermMatcher.contains($0, in: lower) }) {
                return tidy(line)
            }
        }
        if let title = evidence.title?.trimmingCharacters(in: .whitespacesAndNewlines), title.count >= 4, !title.hasPrefix("Microsoft Word") {
            return tidy(title)
        }
        return tidy(evidence.readableFileName)
    }

    /// Words that name a piece of work in a heading.
    static let headingWords = [
        "essay", "report", "project", "presentation", "test", "exam", "examination", "homework", "coursework",
        "assignment", "investigation", "practical", "speech", "seminar", "study", "analysis", "response",
        "proposal", "quiz", "portfolio", "extension", "major work", "research", "internal assessment", "oral", "SAC", "NEA", "IA",
    ].map(TermMatcher.normalize)

    private static func tidy(_ title: String) -> String {
        let collapsed = title.replacing(/\s+/, with: " ").trimmingCharacters(in: CharacterSet(charactersIn: " :-–—"))
        return String(collapsed.prefix(80))
    }

    /// "Weighting: 25%", "worth 30%", "contributes 15%" or "25% of the course".
    static func weighting(in text: String) -> Double? {
        let patterns: [Regex<(Substring, Substring)>] = [
            /\b(?:weighting|weight|worth|value|contributes|counts for)\b[^0-9\n%]{0,25}(\d{1,3}(?:\.\d+)?)\s*%/,
            /(\d{1,3}(?:\.\d+)?)\s*%\s*(?:of\s+(?:the\s+|your\s+)?(?:final|course|total|overall|school|internal|unit|subject)|weighting)/,
        ]
        for pattern in patterns {
            if let match = text.firstMatch(of: pattern), let value = Double(match.output.1), value > 0, value <= 100 {
                return value
            }
        }
        return nil
    }

    /// "Total marks: 40", "Total: 40 marks" or "out of 40".
    static func totalMarks(in text: String) -> Double? {
        let patterns: [Regex<(Substring, Substring)>] = [
            /\btotal(?:\s+marks)?\s*[:=]?\s*(\d{1,3})\b/,
            /\bmarks\s*[:=]\s*(\d{1,3})\b/,
            /\bout of\s+(\d{1,3})\b/,
        ]
        for pattern in patterns {
            if let match = text.firstMatch(of: pattern), let value = Double(match.output.1), value > 0 {
                return value
            }
        }
        return nil
    }

    /// "Time allowed: 2 hours", "Duration: 90 minutes" or "Working time: 1 hour
    /// 30 minutes". Reading time isn't part of it.
    static func lengthMinutes(in text: String) -> Int? {
        let pattern = /\b(?:duration|time allowed|working time|writing time|length|time)\s*[:\-–]?\s*(\d{1,3})\s*(hours?|hrs?|minutes?|mins?)(?:\s+(?:and\s+)?(\d{1,2})\s*(?:minutes?|mins?))?/
        for match in text.matches(of: pattern) {
            let before = text[text.startIndex..<match.range.lowerBound].suffix(8)
            guard !before.hasSuffix("reading "), let amount = Int(match.output.1) else { continue }
            let isHours = match.output.2.hasPrefix("h")
            let extra = match.output.3.flatMap { Int($0) } ?? 0
            let minutes = isHours ? amount * 60 + extra : amount
            if (10...600).contains(minutes) {
                return minutes
            }
        }
        return nil
    }

    /// "Mark: 18/25", "18 / 25", "Grade: B+" or "Band 5".
    static func mark(in text: String) -> Assessment.Mark? {
        var mark = Assessment.Mark()
        if let match = text.firstMatch(of: /\b(?:mark|marks|score|result|total)\s*(?:awarded)?\s*[:=]?\s*(\d{1,3}(?:\.\d)?)\s*(?:\/|out of)\s*(\d{1,3})\b/),
           let score = Double(match.output.1), let outOf = Double(match.output.2), outOf > 0, score <= outOf {
            mark.score = score
            mark.outOf = outOf
        }
        if let match = text.firstMatch(of: /\b(?:grade|band|level)\s*[:=]?\s*([a-e][+-]?|[1-9])(?![a-z0-9])/) {
            let value = String(match.output.1)
            mark.grade = TermMatcher.normalize(String(match.output.0)).hasPrefix("band") ? "Band \(value)" : value.uppercased()
        }
        return mark.score == nil && mark.grade == nil ? nil : mark
    }

    /// Whether a title says enough to be found in other files: "Task 2" alone doesn't.
    static func isDistinctive(_ title: String) -> Bool {
        let generic: Set<String> = ["task", "assessment", "assignment", "exam", "examination", "test", "quiz", "project", "notification", "part", "the", "and", "of", "a"]
        let words = TermMatcher.normalize(title).split { !$0.isLetter }.map(String.init)
        return words.contains { $0.count >= 4 && !generic.contains($0) }
    }
}
