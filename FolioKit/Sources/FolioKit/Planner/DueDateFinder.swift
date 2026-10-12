import Foundation

/// Finds when something is due in an assignment sheet, such as "Due: Friday
/// 14 March, 5 pm". Only dates right after words like "due" or "submit" count,
/// and only future ones, so a history date or an exam's year isn't mistaken
/// for a deadline. The student confirms each one before it's added.
public enum DueDateFinder {
    public struct Found: Hashable, Sendable {
        public var date: Date
        /// The words it was found in, such as "Due date: Friday 14 March 2027".
        public var context: String
        /// The date something is sat or presented, rather than handed in.
        public var isSitting = false
    }

    /// Words that, just before a date, mean it's a deadline.
    static let cues = ["due", "submit", "submission", "deadline", "closes", "hand in", "hand-in", "handed in", "lodge", "lodgement"]

    /// Words that, just before a date, mean an exam, test or in-class task
    /// takes place then. "Date" alone counts here, since it's only used for
    /// files that set an assessment.
    static let sittingCues = [
        "date", "when", "held on", "will be held", "sitting", "takes place", "take place", "deliver", "delivered",
        "in class on", "will be presented", "paper", "quiz on", "test on", "exam on", "examination on", "presentation on",
        "performance", "performances", "interview", "is on",
    ]

    /// Lines that give a date for something else: a payment, a library book,
    /// or the day the task was handed out.
    static let otherDates = ["payment", "pay", "fee", "fees", "invoice", "due back", "due: back", "library", "issued", "issue date", "distributed", "handed out", "$"]

    /// - Parameter includesSittings: When nothing is due, also counts the date
    ///   of an exam, test or in-class task, such as "Date of task: Thursday 12 March".
    public static func dueDate(in text: String, now: Date = .now, calendar: Calendar = .current, includesSittings: Bool = false) -> Found? {
        // The date detector misreads "due 14 March" as today, but reads "due: 14 March" correctly.
        let tidied = text.replacingOccurrences(
            of: #"(?i)\b(due|submit(?:ted)?|submission|deadline|closes|hand(?:ed)?[ -]in)\b(\s+(on|by|date|at))?\s*:?\s*"#,
            with: "$1: ",
            options: .regularExpression
        )
        if let found = firstDate(in: tidied, after: cues, now: now, calendar: calendar) {
            return found
        }
        guard includesSittings else { return nil }
        let sittings = text.replacingOccurrences(
            of: #"(?i)\b((?:exam(?:ination)?|test|task) date|date of (?:the )?(?:task|exam(?:ination)?|test)|(?:will be )?held on|sitting)\b(\s+(on|at))?\s*:?\s*"#,
            with: "$1: ",
            options: .regularExpression
        )
        var found = firstDate(in: sittings, after: sittingCues, now: now, calendar: calendar)
        found?.isSitting = true
        return found
    }

    /// The first future date in `text` with one of `cues` before it on the same line.
    private static func firstDate(in text: String, after cues: [String], now: Date, calendar: Calendar) -> Found? {
        guard let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue) else { return nil }
        let string = text as NSString
        var found: Found?
        detector.enumerateMatches(in: text, range: NSRange(location: 0, length: string.length)) { match, _, stop in
            guard let match, var date = match.date else { return }
            // The same line, up to 60 characters before the date.
            let start = max(0, match.range.location - 60)
            let before = string.substring(with: NSRange(location: start, length: match.range.location - start))
            let rawLine = before.components(separatedBy: .newlines).last ?? before
            let line = rawLine.lowercased()
            guard cues.contains(where: { TermMatcher.contains($0, in: line) }),
                  !otherDates.contains(where: { $0.contains(where: { $0.isPunctuation || $0.isSymbol }) ? line.contains($0) : TermMatcher.contains($0, in: line) })
            else { return }

            let matched = string.substring(with: match.range)
            if !hasTime(matched) {
                // A time just after the date, as in "Tuesday 10 November by 8:30 am", or
                // else the start of the school day, not noon.
                let end = match.range.location + match.range.length
                let after = string.substring(with: NSRange(location: end, length: min(30, string.length - end)))
                let (hour, minute) = time(atStartOf: after.components(separatedBy: .newlines).first ?? after) ?? (9, 0)
                date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
            }
            // "14 March" written in October means next March.
            if date < now, matched.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression) == nil,
               let nextYear = calendar.date(byAdding: .year, value: 1, to: date) {
                date = nextYear
            }
            guard date > now, date.timeIntervalSince(now) < 366 * 24 * 60 * 60 else { return }
            let context = (rawLine + matched).trimmingCharacters(in: .whitespacesAndNewlines)
            found = Found(date: date, context: context)
            stop.pointee = true
        }
        return found
    }

    /// A time such as "by 8:30 am", ", 3 pm" or "at 15:00" at the start of `text`.
    static func time(atStartOf text: String) -> (Int, Int)? {
        let lower = text.lowercased()
        guard let match = lower.firstMatch(of: /^[\s,]*(?:by|at|from|until|before)?\s*(\d{1,2})(?:[:.](\d{2}))?\s*(am|pm|a\.m\.|p\.m\.)?/),
              let hour = Int(match.output.1)
        else { return nil }
        let minute = match.output.2.flatMap { Int($0) } ?? 0
        let meridiem = match.output.3.map(String.init)
        // A bare number isn't a time unless it has minutes, as in "15:00".
        guard meridiem != nil || match.output.2 != nil, hour <= 23, minute <= 59 else { return nil }
        var hour24 = hour
        if let meridiem {
            guard hour >= 1 && hour <= 12 else { return nil }
            hour24 = hour % 12 + (meridiem.hasPrefix("p") ? 12 : 0)
        }
        return (hour24, minute)
    }

    static func hasTime(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.range(of: #"\d{1,2}(:\d{2})?\s*(am|pm|a\.m\.|p\.m\.)"#, options: .regularExpression) != nil
            || lower.range(of: #"\b\d{1,2}:\d{2}\b"#, options: .regularExpression) != nil
            || lower.contains("noon") || lower.contains("midnight")
    }
}
