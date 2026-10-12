import Foundation

/// Looks at the weeks ahead for ones with too much on: more assessment work
/// than a usual week has room for, or three or more things due. For each, it
/// suggests starting earlier on what's due that week and what has work in
/// it, so Plan My Week can spread the work into the quieter weeks before.
/// Room is counted from the student's study times, school and the daily
/// session limit, so starting earlier never plans more than those allow.
///
/// It looks from the week after next: by next week it's too late for an
/// earlier start to help, and what's due then is on Today already. Busy
/// weeks in a row are one stretch, with one set of suggestions.
public struct WorkloadCheck: Sendable {
    public var planner: WeekPlanner

    public init(planner: WeekPlanner) {
        self.planner = planner
    }

    /// Starting an assessment earlier, from a day.
    public struct Suggestion: Sendable, Equatable, Identifiable {
        public var id: Assessment.ID { assessmentID }
        public var assessmentID: Assessment.ID
        public var title: String
        public var from: Date
    }

    public struct Warning: Sendable, Equatable, Identifiable {
        public var id: Date { week.start }
        /// The busy week, or weeks in a row.
        public var week: DateInterval
        /// Open assessments due that week, soonest first.
        public var due: [Assessment]
        /// Three or more things due, leaving out homework.
        public var isCrowded: Bool
        /// Minutes of assessment work Plan My Week would want in the busiest week.
        public var workMinutes: Int
        /// Minutes of study a usual week has room for.
        public var roomMinutes: Int
        public var startEarlier: [Suggestion]

        /// More work than fits, leaving a fifth of the week for everything else.
        public var isTooMuchWork: Bool { workMinutes * 5 > roomMinutes * 4 }
    }

    /// How many things due in one week makes it crowded, leaving out homework.
    public static let crowded = 3
    /// How much earlier to start.
    public static let daysEarlier = 7
    /// An earlier start that moves less than this isn't worth suggesting.
    public static let leastDaysEarlier = 3

    /// Stretches of busy weeks from the week after next, looking `weeks` ahead, soonest first.
    public func warnings(assessments: [Assessment], sessions: [StudySession], now: Date, weeks: Int = 6) -> [Warning] {
        let calendar = planner.calendar
        let today = calendar.startOfDay(for: now)
        guard let thisWeek = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        let open = assessments.filter { $0.isOpen(at: now) }

        let busyWeeks = (2...max(2, weeks + 1)).compactMap { offset -> Warning? in
            guard let start = calendar.date(byAdding: .day, value: 7 * offset, to: thisWeek),
                  let end = calendar.date(byAdding: .day, value: 7, to: start)
            else { return nil }
            let due = open.filter { $0.due >= start && $0.due < end }.sorted { $0.due < $1.due }
            let shares = open.map { assessment in
                (assessment, planner.demands(for: assessment, weekStart: start, weekEnd: end, now: now, existing: sessions).reduce(0) { $0 + $1.minutes })
            }
            let work = shares.reduce(0) { $0 + $1.1 }
            var warning = Warning(
                week: DateInterval(start: start, end: end), due: due,
                isCrowded: due.filter { $0.kind != .homework }.count >= Self.crowded,
                workMinutes: work, roomMinutes: room(inWeekStarting: start, now: now), startEarlier: []
            )
            guard warning.isTooMuchWork || warning.isCrowded else { return nil }

            // What's due that week, and what has work in it.
            var seen = Set<Assessment.ID>()
            let candidates = (due + shares.filter { $0.1 > 0 }.map(\.0))
                .filter { $0.kind != .homework && seen.insert($0.id).inserted }
                .sorted { $0.due < $1.due }
            warning.startEarlier = candidates.compactMap { assessment in
                guard let usual = assessment.workStart(calendar: calendar),
                      let earlier = calendar.date(byAdding: .day, value: -Self.daysEarlier, to: usual)
                else { return nil }
                let from = max(today, earlier)
                let moved = calendar.dateComponents([.day], from: from, to: usual).day ?? 0
                return moved >= Self.leastDaysEarlier ? Suggestion(assessmentID: assessment.id, title: assessment.title, from: from) : nil
            }
            return warning
        }

        // Busy weeks in a row are one stretch.
        var stretches: [Warning] = []
        for warning in busyWeeks {
            guard var last = stretches.last, last.week.end == warning.week.start else {
                stretches.append(warning)
                continue
            }
            last.week = DateInterval(start: last.week.start, end: warning.week.end)
            last.due += warning.due.filter { assessment in !last.due.contains { $0.id == assessment.id } }
            last.isCrowded = last.isCrowded || warning.isCrowded
            if warning.workMinutes > last.workMinutes {
                last.workMinutes = warning.workMinutes
                last.roomMinutes = warning.roomMinutes
            }
            last.startEarlier += warning.startEarlier.filter { suggestion in !last.startEarlier.contains { $0.assessmentID == suggestion.assessmentID } }
            stretches[stretches.count - 1] = last
        }
        return stretches
    }

    /// The minutes of study a week starting `weekStart` has room for: sessions
    /// that fit in each day's free study time, up to the daily limit. Events
    /// in the student's calendar aren't counted, since weeks ahead are mostly
    /// still to be filled.
    public func room(inWeekStarting weekStart: Date, now: Date) -> Int {
        let preferences = planner.preferences
        let session = Double(preferences.sessionMinutes * 60)
        let gap = Double(preferences.breakMinutes * 60)
        return (0..<7).reduce(0) { total, offset in
            guard let day = planner.calendar.date(byAdding: .day, value: offset, to: weekStart) else { return total }
            let fits = planner.freeWindows(on: day, after: now, busy: []).reduce(0) { $0 + Int(($1.duration + gap) / (session + gap)) }
            return total + min(fits, preferences.maxSessionsPerDay) * preferences.sessionMinutes
        }
    }
}
