import SwiftUI
import FolioKit

/// Every assessment: what's coming up, what's handed in, and what's marked.
struct AssessmentList: View {
    @Environment(AppModel.self) private var model
    @State private var editing: Assessment?

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            if model.assessments.isEmpty {
                ContentUnavailableView(
                    "No assessments yet",
                    systemImage: "checklist",
                    description: Text("Add your tasks and exams, or drop a task sheet on Folio and it will offer to add it.")
                )
                .padding(.top, 60)
            }
            group("Coming up", upcoming)
            group("Overdue", overdue)
            group("Submitted", model.assessments.filter { $0.status == .submitted }.sorted { $0.due > $1.due })
            group("Marked", model.assessments.filter { $0.status == .marked }.sorted { $0.due > $1.due })
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .sheet(item: $editing) { assessment in
            AssessmentSheet(assessment: assessment)
        }
    }

    private var upcoming: [Assessment] {
        model.assessments.filter { !$0.isDone && $0.due >= model.calendar.startOfDay(for: .now) }
    }

    private var overdue: [Assessment] {
        model.assessments.filter { !$0.isDone && $0.due < model.calendar.startOfDay(for: .now) }
    }

    @ViewBuilder
    private func group(_ title: LocalizedStringKey, _ assessments: [Assessment]) -> some View {
        if !assessments.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(title)
                VStack(spacing: 0) {
                    ForEach(assessments) { assessment in
                        AssessmentRow(assessment: assessment)
                            .padding(.horizontal, 16)
                            .assessmentActions(assessment, edit: { editing = assessment })
                        if assessment.id != assessments.last?.id {
                            Rectangle()
                                .fill(Theme.separator)
                                .frame(height: 1)
                                .padding(.leading, 60)
                        }
                    }
                }
                .background(RoundedRectangle(cornerRadius: Theme.Radius.list).fill(Theme.cardBackground))
            }
        }
    }
}

/// One assessment: its kind, title, subject, when, how much it counts, and its
/// status or mark. Compact rows leave out the icon, for narrow panels.
struct AssessmentRow: View {
    @Environment(AppModel.self) private var model
    let assessment: Assessment
    var compact = false

    var body: some View {
        let subject = model.subject(assessment.subjectID)
        HStack(spacing: 14) {
            if !compact {
                IconTile(
                    systemName: assessment.kind.systemImage,
                    foreground: subject?.tintForeground ?? Theme.primaryText,
                    background: subject?.tintBackground ?? Color.white.opacity(0.1),
                    symbolSize: 15
                )
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(assessment.title)
                    .font(.system(size: 14, weight: .medium))
                    .lineLimit(compact ? 2 : 1)
                HStack(spacing: 7) {
                    SubjectDot(color: subject?.color ?? .gray)
                    Text(details(subject: subject))
                        .font(.system(size: 12.5))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 8)
            if !compact {
                trailing
            }
        }
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    /// "Biology · Fri 14 Nov · 30%", with "Exam" or "Test" for sittings.
    private func details(subject: Subject?) -> String {
        var parts: [String] = []
        if let name = subject?.name {
            parts.append(name)
        }
        if assessment.isSitting {
            parts.append(String(localized: assessment.kind.title))
            parts.append(assessment.due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).hour().minute()))
        } else {
            parts.append(assessment.due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
        }
        if let weighting = assessment.weightingText {
            parts.append(weighting)
        }
        if compact && !assessment.isDone {
            parts.append(model.countdown(to: assessment.due))
        }
        return parts.joined(separator: " · ")
    }

    @ViewBuilder private var trailing: some View {
        if let mark = assessment.markText {
            Text(mark)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
        } else if assessment.isDone {
            Text(assessment.status.title)
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.secondaryText)
        } else {
            VStack(alignment: .trailing, spacing: 2) {
                Text(model.countdown(to: assessment.due))
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(assessment.due < .now ? Theme.warning : Theme.primaryText)
                Text(assessment.status.title)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.secondaryText)
            }
        }
    }
}

extension View {
    /// Opens the assessment with a double-click or Return, and offers its
    /// status changes in a context menu and to VoiceOver.
    func assessmentActions(_ assessment: Assessment, edit: @escaping () -> Void) -> some View {
        modifier(AssessmentActions(assessment: assessment, edit: edit))
    }
}

private struct AssessmentActions: ViewModifier {
    @Environment(AppModel.self) private var model
    let assessment: Assessment
    let edit: () -> Void

    func body(content: Content) -> some View {
        content
            .contentShape(Rectangle())
            .onTapGesture(count: 2, perform: edit)
            // Keyboard and VoiceOver users open it with Return or the default action.
            .focusable()
            .onKeyPress(.return) {
                edit()
                return .handled
            }
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { edit() }
            .accessibilityAction(named: assessment.isSitting ? "Mark as Done" : "Mark as Submitted") {
                withAnimation(Theme.motion()) { model.setStatus(.submitted, of: assessment) }
            }
            .contextMenu {
                Button("Edit…", action: edit)
                Divider()
                ForEach(Assessment.Status.allCases, id: \.self) { status in
                    Button {
                        withAnimation(Theme.motion()) { model.setStatus(status, of: assessment) }
                    } label: {
                        if status == assessment.status {
                            Label(String(localized: status.title), systemImage: "checkmark")
                        } else {
                            Text(status.title)
                        }
                    }
                }
                Divider()
                Button("Delete", role: .destructive) {
                    withAnimation(Theme.motion()) { model.deleteAssessment(assessment) }
                }
            }
    }
}
