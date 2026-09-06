import AppIntents

struct RelayShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: StartRecordingIntent(),
            phrases: [
                "Start recording in \(.applicationName)",
                "Record with \(.applicationName)"
            ],
            shortTitle: "Start Recording",
            systemImageName: "mic.fill"
        )
        AppShortcut(
            intent: ImportRecordingIntent(),
            phrases: [
                "Import a recording into \(.applicationName)"
            ],
            shortTitle: "Import Recording",
            systemImageName: "square.and.arrow.down"
        )
        AppShortcut(
            intent: ExportRecordingIntent(),
            phrases: [
                "Export a recording from \(.applicationName)"
            ],
            shortTitle: "Export Recording",
            systemImageName: "square.and.arrow.up"
        )
    }
}
