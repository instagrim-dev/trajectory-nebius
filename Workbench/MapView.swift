import SwiftUI
import WorkbenchCore

/// Decision Map: a vertical Requirements → Question → fork → Programs
/// stack. Node meanings stay triple-distinct: Selected (ring),
/// Accepted (teal fill), Viewing (border + caption). Opening a program
/// sets the viewed program; it never constructs anything.
struct MapView: View {
    var model: WorkbenchModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Label("Requirements", systemImage: "tray.full")
                Label("Owner question", systemImage: "questionmark.circle")
            } header: {
                Text("Path")
            }
            Section {
                Text("Selected is the branch you are exploring. Accepted is the current rule.")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    Label("When is access checked?", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.subheadline.weight(.semibold))
                    DecisionForkLines().stroke(Color.secondary.opacity(0.6), lineWidth: 1.5)
                        .frame(height: 28).accessibilityHidden(true)
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Answer.allCases, id: \.self) { answer in
                            Button { model.select(answer) } label: {
                                MapNodeRow(
                                    title: answer.title,
                                    systemImage: answer == .queueTime ? "clock" : "paperplane",
                                    isSelected: model.state.selected == answer,
                                    isAccepted: model.state.accepted == answer,
                                    isViewing: viewedAnswer == answer
                                )
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                            .accessibilityLabel("Answer node. \(answer.title).")
                            .accessibilityHint("Selects this branch. Selecting never accepts.")
                            .accessibilityIdentifier("map-answer-\(answer.rawValue)")
                        }
                    }
                }

            } header: {
                Text("Fork")
            }
            Section {
                ForEach(SampleProgram.allCases, id: \.self) { program in
                    // Plain NavigationLink: ProgramView.onAppear records the
                    // viewed program. An extra TapGesture here competes with
                    // link activation — the gesture fires (viewed changes)
                    // while the push never happens — so it must not exist.
                    NavigationLink(value: program) {
                        MapNodeRow(
                            title: "Program \(program.versionLabel)",
                            systemImage: "doc.plaintext",
                            isSelected: false,
                            isAccepted: false,
                            isViewing: model.state.viewed == program
                        )
                    }
                    .accessibilityIdentifier("map-program-\(program.rawValue)")
                    .accessibilityHint("Opens the saved program for viewing. Reopening never changes accepted intent.")
                }
            } header: {
                Text("Saved programs")
            } footer: {
                Text("Viewing: \(model.state.viewed.versionLabel). Latest accepted: \(model.state.accepted.title).")
            }
        }
        // Same floating-toolbar clearance as Conversation: the saved-program
        // rows must scroll clear so taps land on the row, not the toolbar.
        .contentMargins(.bottom, 96, for: .scrollContent)
        .navigationTitle("Decision Map")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button {
                    dismiss()
                } label: {
                    Label("Back", systemImage: "chevron.backward")
                }
                .accessibilityIdentifier("map-back")
                .accessibilityHint("Returns to the owner question. Nothing is selected, accepted, or changed.")
                Button {
                    model.select(otherAnswer(model.state.selected))
                } label: {
                    Label("Across", systemImage: "arrow.left.arrow.right")
                }
                .accessibilityIdentifier("map-across")
                .accessibilityHint("Moves selection to the other answer.")
            }
        }
    }

    private var viewedAnswer: Answer { model.state.viewed.answer }
}

private func otherAnswer(_ answer: Answer) -> Answer {
    answer == .queueTime ? .deliveryTime : .queueTime
}

private struct MapNodeRow: View {
    var title: String
    var systemImage: String
    var isSelected: Bool
    var isAccepted: Bool
    var isViewing: Bool

    var body: some View {
        HStack {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.body)
                    .foregroundStyle(.primary)
                HStack(spacing: 8) {
                    if isSelected {
                        Text("Selected").font(.caption).foregroundStyle(Color.accentColor)
                    }
                    if isAccepted {
                        Text("Accepted").font(.caption).foregroundStyle(Color.trajectoryTeal)
                    }
                    if isViewing {
                        Text("Viewing").font(.caption).foregroundStyle(Color.accentColor)
                    }
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .frame(minHeight: 44)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 2)
            } else if isViewing {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 1)
            }
        }
        .background {
            if isAccepted {
                RoundedRectangle(cornerRadius: 10).fill(Color.trajectoryTeal.opacity(0.12))
            }
        }
    }
}
