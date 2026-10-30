import SwiftUI
import WorkbenchCore

/// Adaptive root. Compact width (iPhone) is an explicit NavigationStack
/// rooted at the Conversation — the approved phone spine starts at the
/// owner question, never at a sidebar. Regular width (iPad) is a split
/// whose sidebar links and saved-program rows drive real detail.
///
/// Destination registrations live with the stacks that host them:
/// ConversationView (the root of both detail stacks) registers
/// Destination + SampleProgram pushes for the compact stack and the
/// regular detail stack, and Sidebar registers the same types for links
/// originating in the sidebar column.
struct WorkbenchRoot: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    var model: WorkbenchModel

    var body: some View {
        if sizeClass == .compact {
            NavigationStack {
                ConversationView(model: model)
            }
        } else {
            NavigationSplitView {
                Sidebar(model: model)
            } detail: {
                NavigationStack {
                    ConversationView(model: model)
                }
            }
        }
    }
}

private struct Sidebar: View {
    var model: WorkbenchModel

    var body: some View {
        List {
            Section("Workbench") {
                NavigationLink(value: Destination.conversation) {
                    Label("Conversation", systemImage: "bubble.left.and.bubble.right")
                }
                NavigationLink(value: Destination.map) {
                    Label("Decision Map", systemImage: "map")
                }
                NavigationLink(value: Destination.report) {
                    Label("Report", systemImage: "checklist")
                }
                NavigationLink(value: Destination.live) {
                    Label("Live", systemImage: "cable.connector")
                }
            }
            Section("Sample programs") {
                ForEach(SampleProgram.allCases, id: \.self) { program in
                    // Plain NavigationLink: ProgramView.onAppear records the
                    // viewed program. A TapGesture here would compete with
                    // link activation the same way it did on the Map rows.
                    NavigationLink(value: program) {
                        LabeledContent(program.versionLabel, value: program.sourceIdentityPrefix)
                    }
                    .accessibilityLabel("View saved program \(program.versionLabel)")
                    .accessibilityHint("Opens the saved program detail. Reopening never changes accepted intent.")
                }
            }
        }
        .navigationTitle("Workbench")
        .navigationDestination(for: Destination.self) { destination in
            switch destination {
            case .conversation: ConversationView(model: model)
            case .map: MapView(model: model)
            case .report: ReportView(model: model)
            case .live: LiveWorkbenchView(live: model.live)
            }
        }
        .navigationDestination(for: SampleProgram.self) { program in
            ProgramView(model: model, program: program)
        }
    }
}

enum Destination: Hashable {
    case conversation
    case map
    case report
    case live
}
