#if DEBUG
import SwiftUI
import FolioKit

extension AppModel {
    /// The sample content from the design mock-ups, placed around today's date,
    /// for previews and render shots. Debug builds only.
    static func sample(now: Date = .now) -> AppModel {
        let calendar = makeCalendar()

        // The starter profile's subjects, in the design's order:
        // Mathematics, English, Physics, Chemistry, History.
        var profile = Profile.starter()
        profile.studentName = "Sam"
        profile.subjects[1].teachers = ["Ms Patel"]
        profile.subjects[2].teachers = ["Mr Okafor"]
        let subjects = profile.subjects
        let (maths, english, physics, chemistry, history) = (subjects[0], subjects[1], subjects[2], subjects[3], subjects[4])
        let folders: [Subject.ID: [SubjectFolder]] = [
            maths.id: [
                SubjectFolder(name: "Notes", fileCount: 12),
                SubjectFolder(name: "Worksheets", fileCount: 10),
                SubjectFolder(name: "Practice", fileCount: 9),
                SubjectFolder(name: "Past Papers", fileCount: 7),
            ],
            english.id: [
                SubjectFolder(name: "Essays", fileCount: 9),
                SubjectFolder(name: "Notes", fileCount: 8),
                SubjectFolder(name: "Texts", fileCount: 6),
                SubjectFolder(name: "Past Papers", fileCount: 4),
            ],
            physics.id: [
                SubjectFolder(name: "Notes", fileCount: 11),
                SubjectFolder(name: "Worksheets", fileCount: 8),
                SubjectFolder(name: "Practicals", fileCount: 7),
                SubjectFolder(name: "Past Papers", fileCount: 5),
            ],
            chemistry.id: [
                SubjectFolder(name: "Notes", fileCount: 9),
                SubjectFolder(name: "Practicals", fileCount: 6),
                SubjectFolder(name: "Worksheets", fileCount: 4),
                SubjectFolder(name: "Past Papers", fileCount: 3),
            ],
            history.id: [
                SubjectFolder(name: "Notes", fileCount: 8),
                SubjectFolder(name: "Sources", fileCount: 5),
                SubjectFolder(name: "Essays", fileCount: 4),
                SubjectFolder(name: "Past Papers", fileCount: 2),
            ],
        ]

        let week = calendar.dateInterval(of: .weekOfYear, for: now)?.start ?? calendar.startOfDay(for: now)
        func time(day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
            let date = calendar.date(byAdding: .day, value: day, to: week) ?? week
            return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: date) ?? date
        }
        func session(_ subject: Subject, day: Int, from start: (Int, Int), to end: (Int, Int), for assessment: Assessment? = nil) -> StudySession {
            let begins = time(day: day, start.0, start.1)
            var title = assessment?.title
            if let assessment, let milestone = assessment.nextMilestone(after: begins) {
                title = "\(assessment.title): \(milestone.title)"
            }
            return StudySession(subjectID: subject.id, start: begins, end: time(day: day, end.0, end.1), assessmentID: assessment?.id, title: title)
        }

        var essay = Assessment(title: "Poetry analysis essay", subjectID: english.id, due: time(day: 4, 9), weighting: 25, status: .inProgress)
        essay.milestones = [Assessment.Milestone(title: String(localized: "Draft"), date: time(day: 2, 17))]
        let report = Assessment(title: "Projectile motion report", subjectID: physics.id, kind: .practical, due: time(day: 8, 9), weighting: 20)
        let test = Assessment(title: "Calculus topic test", subjectID: maths.id, kind: .test, due: time(day: 10, 11), lengthMinutes: 50, weighting: 10)
        let trial = Assessment(title: "Chemistry trial exam", subjectID: chemistry.id, kind: .exam, due: time(day: 12, 9), lengthMinutes: 180, room: "Hall", weighting: 30)
        let marked = Assessment(
            title: "Source analysis", subjectID: history.id, due: time(day: -10, 9), weighting: 20, totalMarks: 25, status: .marked,
            mark: Assessment.Mark(score: 21, outOf: 25, grade: "A"), feedback: "Strong use of sources; tighten the conclusion."
        )

        return AppModel(
            calendar: calendar,
            profile: profile,
            folders: folders,
            recentlySorted: [
                SortedFile(name: "Projectile Motion Worksheet.pdf", subjectID: physics.id, folder: "Worksheets", sortedAt: now.addingTimeInterval(-120)),
                SortedFile(name: "Poetry Analysis Draft.docx", subjectID: english.id, folder: "Essays", sortedAt: now.addingTimeInterval(-130)),
                SortedFile(name: "Integration Practice Set.pdf", subjectID: maths.id, folder: "Practice", sortedAt: now.addingTimeInterval(-26 * 60 * 60)),
            ],
            sorting: [
                SortingItem(name: "Week 3 Vectors Worksheet.pdf", detail: "Worksheet · 3 pages", status: .filed(subjectID: maths.id, folder: "Worksheets")),
                SortingItem(name: "IMG_4021.heic", detail: "Photo of handwritten notes · text read", status: .filed(subjectID: physics.id, folder: "Notes")),
                SortingItem(name: "Poetry Analysis Draft.docx", detail: "Essay draft · 1,240 words", status: .filed(subjectID: english.id, folder: "Essays")),
                SortingItem(name: "scan0007.pdf", detail: "Reading page 2 of 5…", status: .reading),
            ],
            needsReview: [
                ReviewItem(
                    name: "Untitled 2.pdf",
                    question: "Could be Chemistry or Physics. Which one should it go to?",
                    suggestions: [chemistry.id, physics.id],
                    folder: nil
                ),
            ],
            sessions: [
                session(maths, day: 0, from: (16, 0), to: (17, 30)),
                session(english, day: 0, from: (18, 0), to: (19, 0), for: essay),
                session(physics, day: 1, from: (16, 0), to: (17, 0), for: report),
                session(chemistry, day: 1, from: (17, 30), to: (19, 0)),
                session(history, day: 2, from: (16, 0), to: (17, 30)),
                session(maths, day: 3, from: (16, 0), to: (17, 0)),
                session(physics, day: 3, from: (17, 30), to: (19, 0)),
                session(english, day: 3, from: (19, 30), to: (20, 30), for: essay),
                session(chemistry, day: 5, from: (9, 0), to: (11, 0), for: trial),
                session(maths, day: 5, from: (11, 30), to: (13, 0)),
                session(history, day: 6, from: (10, 0), to: (11, 30)),
                session(physics, day: 6, from: (14, 0), to: (15, 30)),
            ],
            assessments: [marked, essay, report, test, trial]
        )
    }
}
#endif
