import Foundation
import SwiftData

/// Version 2 adds the planner's study sessions and deadlines, so they're kept
/// between launches.
///
/// Models that didn't change are shared with version 1. A model that changes
/// later must first be copied into a new version, so that version 1 still
/// describes stores saved by Folio 0.1.
public enum FolioSchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }

    public static var models: [any PersistentModel.Type] {
        FolioSchemaV1.models + [PlannedSession.self, DeadlineRecord.self]
    }

    /// A study session in the planner.
    @Model public final class PlannedSession {
        @Attribute(.unique) public var id: UUID
        public var subjectID: UUID
        public var start: Date
        public var end: Date

        public init(id: UUID = UUID(), subjectID: UUID, start: Date, end: Date) {
            self.id = id
            self.subjectID = subjectID
            self.start = start
            self.end = end
        }

    }

    /// Something due, such as an assignment or a test.
    @Model public final class DeadlineRecord {
        @Attribute(.unique) public var id: UUID
        public var title: String
        public var subjectID: UUID
        public var due: Date
        public var isDone: Bool
        /// The matching reminder in Apple Reminders, when Folio added one.
        public var reminderID: String?
        /// The file the due date was found in, if any.
        public var sourcePath: String?
        public var createdAt: Date

        public init(id: UUID = UUID(), title: String, subjectID: UUID, due: Date, isDone: Bool = false, reminderID: String? = nil, sourcePath: String? = nil, createdAt: Date = .now) {
            self.id = id
            self.title = title
            self.subjectID = subjectID
            self.due = due
            self.isDone = isDone
            self.reminderID = reminderID
            self.sourcePath = sourcePath
            self.createdAt = createdAt
        }
    }
}

/// How stores saved by earlier versions of Folio are brought up to date.
public enum FolioMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] {
        [FolioSchemaV1.self, FolioSchemaV2.self, FolioSchemaV3.self, FolioSchemaV4.self, FolioSchemaV5.self]
    }

    public static var stages: [MigrationStage] {
        // Version 2 only adds new kinds of record, version 3 only adds optional
        // fields, and versions 4 and 5 both, so SwiftData can do them all itself.
        [
            .lightweight(fromVersion: FolioSchemaV1.self, toVersion: FolioSchemaV2.self),
            .lightweight(fromVersion: FolioSchemaV2.self, toVersion: FolioSchemaV3.self),
            .lightweight(fromVersion: FolioSchemaV3.self, toVersion: FolioSchemaV4.self),
            .lightweight(fromVersion: FolioSchemaV4.self, toVersion: FolioSchemaV5.self),
        ]
    }
}
