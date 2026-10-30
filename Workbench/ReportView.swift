import SwiftUI
import WorkbenchCore

/// Report: the one true binding of the viewed program against the
/// latest accepted intent, with pass/fail on a separate line.
/// "No report" never renders as a historical pass.
struct ReportView: View {
    var model: WorkbenchModel
    @State private var viewedChoice: SampleProgram = .v1

    private var binding: ReportBinding { model.state.reportBinding }

    var body: some View {
        List {
            Section {
                LabeledContent("Latest accepted", value: model.state.accepted.title)
                Picker("Viewed program", selection: $viewedChoice) {
                    ForEach(SampleProgram.allCases, id: \.self) { program in
                        Text(program.versionLabel).tag(program)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: viewedChoice) { _, program in
                    model.openProgram(program)
                }
                .accessibilityIdentifier("report-viewed-picker")
                .accessibilityHint("Reopens the saved program for viewing. Reopening never changes accepted intent.")
            } header: {
                Text("Binding")
            }
            Section {
                HStack(spacing: 8) {
                    Image(systemName: bindingIcon)
                        .foregroundStyle(Color.trajectoryTeal)
                    Text(binding.title)
                        .font(.headline)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Applicability: \(binding.title).")
                Text(bindingExplanation)
                    .font(.body)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Applicability")
            }
            Section {
                Text(model.observationLine(for: model.state.viewed))
                    .font(.body)
            } header: {
                Text("Outcome")
            } footer: {
                Text("Checks never authorize release — this product has no apply action.")
            }
        }
        .navigationTitle("Report")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { viewedChoice = model.state.viewed }
    }

    private var bindingIcon: String {
        switch binding {
        case .unchecked: "questionmark.circle"
        case .current: "checkmark.circle"
        case .historical: "clock.arrow.circlepath"
        case .mismatched: "exclamationmark.triangle"
        }
    }

    private var bindingExplanation: String {
        switch binding {
        case .unchecked:
            "No retained observation exists for this program. This is not a pass."
        case .current:
            "The viewed program matches the latest accepted intent and a retained check exists for it."
        case .historical:
            "The retained check is valid for this saved branch only — the latest accepted intent points elsewhere."
        case .mismatched:
            "The retained check no longer matches source, contract, or environment. It verifies nothing."
        }
    }
}

/// Sample provenance summary. Full detail lives in docs/provenance.md,
/// outside this core flow.
struct AboutSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Spacer()
                        BrandMark(size: 120)
                        Spacer()
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Returning Stair emblem")
                    Text("This workbench shows authored sample content only: a two-answer queued-export question, two saved sample programs, and retained fixture observations.")
                        .font(.body)
                } header: {
                    Text("Sample")
                }
                Section {
                    Text("Nothing here constructs programs, runs checks, contacts a service, or uses credentials. See docs/provenance.md in the repository for source inputs and authorship.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Provenance")
                }
            }
            .navigationTitle("About")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }
}


/// Two conceptual workflows, independent of any particular example.
struct TrajectoryConceptView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let ink = Color(red: 0.05, green: 0.08, blue: 0.13)
    private let mint = Color(red: 0.30, green: 0.91, blue: 0.78)
    private let pink = Color(red: 1, green: 0.43, blue: 0.69)

    var body: some View {
        VStack(spacing: 12) {
            TimelineView(.periodic(from: .now, by: 1.2)) { timeline in
                let phase = reduceMotion ? -1 : Int(timeline.date.timeIntervalSinceReferenceDate / 1.2) % 4
                VStack(alignment: .leading, spacing: 14) {
                    Text("AGENTIC FLOW").font(.caption.weight(.bold)).tracking(1).foregroundStyle(pink)
                    Text("Explore. Act. Adapt.").font(.title3.weight(.bold)).foregroundStyle(.white)
                    Text("The agent plans, acts, inspects, and adapts its next step.")
                        .font(.subheadline).foregroundStyle(.white.opacity(0.78))
                    HStack(spacing: 8) {
                        node("PLAN", active: phase == 0, tint: pink)
                        node("ACT", active: phase == 1, tint: pink)
                    }
                    HStack(spacing: 8) {
                        node("ADAPT", active: phase == 3, tint: pink)
                        node("INSPECT", active: phase == 2, tint: pink)
                    }
                    Text("A continuing loop of exploration")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(ink, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Agentic flow. The agent plans, acts, inspects, and adapts in a continuing loop.")
            }
            TimelineView(.periodic(from: .now, by: 1.2)) { timeline in
                let phase = reduceMotion ? -1 : Int(timeline.date.timeIntervalSinceReferenceDate / 1.2) % 4
                VStack(alignment: .leading, spacing: 10) {
                    Text("DECISION-BASED FLOW").font(.caption.weight(.bold)).tracking(1).foregroundStyle(mint)
                    Text("Make the choice visible.").font(.title3.weight(.bold)).foregroundStyle(.white)
                    node("GOAL + CONSTRAINTS", active: phase == 0, tint: mint)
                    arrow
                    HStack(spacing: 6) {
                        node("OPTION A", active: phase == 1, tint: mint)
                        node("OPTION B", active: phase == 1, tint: mint)
                        node("OPTION C", active: phase == 1, tint: mint)
                    }
                    Text("COMPARE OPTIONS").font(.caption2.weight(.bold)).foregroundStyle(.white.opacity(0.7))
                        .frame(maxWidth: .infinity)
                    arrow
                    node("AUTHORIZE → APPLY", active: phase == 2, tint: mint)
                    arrow
                    node("VERIFY THE OUTCOME", active: phase == 3, tint: mint)
                    Text("Choices, changes, and outcomes remain inspectable.")
                        .font(.caption).foregroundStyle(.white.opacity(0.7))
                }
                .padding(18).frame(maxWidth: .infinity, alignment: .leading)
                .background(ink, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("Decision-based flow. Define the goal and constraints, compare options, authorize and apply a choice, and verify the outcome.")
            }
        }.padding(.vertical, 6)
    }

    private var arrow: some View {
        Image(systemName: "arrow.down").foregroundStyle(mint).frame(maxWidth: .infinity)
    }

    private func node(_ label: String, active: Bool, tint: Color) -> some View {
        Text(label).font(.caption2.weight(.bold)).multilineTextAlignment(.center)
            .foregroundStyle(active ? tint : .white.opacity(0.85))
            .frame(maxWidth: .infinity, minHeight: 40).padding(.horizontal, 4)
            .background(tint.opacity(active ? 0.18 : 0.05), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(active ? 1 : 0.35), lineWidth: active ? 2 : 1))
    }
}
