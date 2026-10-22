import AppKit

/// The entry point. Parses the snapshot-rendering arguments before SwiftUI creates any scene.
/// Snapshot rendering never enters CRDWindowStudioApp.main(), so no settings window, Dock icon,
/// login item or helper command is involved.
@main enum StudioEntry {
    @MainActor static func main() {
        do {
            if let request = try SnapshotRequest.parse(CommandLine.arguments) {
                SnapshotRenderer.run(request)
            } else {
                CRDWindowStudioApp.main()
            }
        } catch {
            FileHandle.standardError.write(Data("snapshot: \(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }
}
