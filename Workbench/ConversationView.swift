import SwiftUI
import WorkbenchCore

/// Conversation is the root: the queued-export request, the owner
/// question, and the two answers. Tapping an answer selects it;
/// only the explicit Accept button accepts.
struct ConversationView: View {
    var model: WorkbenchModel

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                Text(model.requestSummary)
                    .font(.body)
                HStack {
                    BrandMark(size: 28)
                    Text("Sample workspace")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.secondary.opacity(0.15), in: Capsule())
                    Spacer()
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Sample workspace. Sample data.")
            } header: {
                Text("Customer records request")
            }

            Section {
                Text(model.ownerQuestion)
                    .font(.headline)
                    .foregroundStyle(Color.trajectoryNavy)
                ForEach(model.transcript, id: \.self) { line in
                    Text(line)
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Owner question")
            }

            Section {
                Text("Select explores a branch; Accept makes it the current rule.")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(spacing: 0) {
                    Label("When is access checked?", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.subheadline.weight(.semibold))
                    DecisionForkLines().stroke(Color.secondary.opacity(0.6), lineWidth: 1.5)
                        .frame(height: 28).accessibilityHidden(true)
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(Answer.allCases, id: \.self) { answer in
                            AnswerRow(answer: answer,
                                      isSelected: model.state.selected == answer,
                                      isAccepted: model.state.accepted == answer) {
                                model.select(answer)
                            }
                            .frame(maxWidth: .infinity, alignment: .topLeading)
                        }
                    }
                }
                Button {
                    model.accept()
                } label: {
                    Text("Accept selected answer")
                        .frame(maxWidth: .infinity)
                        .frame(minHeight: 50)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.trajectoryTeal)
                .accessibilityIdentifier("accept-selected")
                .disabled(!model.state.isAcceptEnabled)
                .accessibilityHint(
                    model.state.isAcceptEnabled
                        ? "Accepts the selected answer as owner intent."
                        : "Disabled. The selected answer is already accepted."
                )
            } header: {
                Text("Answers")
            } footer: {
                Text("Sample data — selecting previews, accepting decides. Nothing is constructed or checked here.")
            }

            Section("How Trajectory works") {
                TrajectoryConceptView()
                    .accessibilityIdentifier("trajectory-concept")
                    .listRowInsets(EdgeInsets())
            }
        }
        // The bottom toolbar floats over list content: keep the last rows
        // and the Accept button scrollable clear of it so every row stays
        // tappable and reachable. Rest position is unchanged.
        .contentMargins(.bottom, 96, for: .scrollContent)
        .navigationTitle("CCPA Records Request")
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                NavigationLink(value: Destination.map) {
                    Label("Map", systemImage: "map")
                }
                .accessibilityIdentifier("toolbar-map")
                Button {
                    model.showingPreview = true
                } label: {
                    Label("Preview", systemImage: "doc.text.magnifyingglass")
                }
                .accessibilityIdentifier("toolbar-preview")
                Button {
                    model.showingCompare = true
                } label: {
                    Label("Compare", systemImage: "arrow.left.arrow.right")
                }
                .accessibilityIdentifier("toolbar-compare")
                NavigationLink(value: Destination.report) {
                    Label("Report", systemImage: "checklist")
                }
                .accessibilityIdentifier("toolbar-report")
                NavigationLink(value: Destination.live) {
                    Label("Live", systemImage: "cable.connector")
                }
                .accessibilityIdentifier("toolbar-live")
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    model.showingAbout = true
                } label: {
                    Label("About this sample", systemImage: "info.circle")
                }
                .accessibilityLabel("About this sample")
            }
        }
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
        .sheet(isPresented: $model.showingPreview) {
            PreviewSheet(model: model)
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $model.showingCompare) {
            CompareView(model: model)
                .presentationDetents([.large])
        }
        .sheet(isPresented: $model.showingAbout) {
            AboutSheet()
        }
    }
}

private struct AnswerRow: View {
    var answer: Answer
    var isSelected: Bool
    var isAccepted: Bool
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(answer.title)
                        .font(.body)
                        .foregroundStyle(.primary)
                    HStack(spacing: 8) {
                        if isSelected {
                            Label("Selected", systemImage: "circle.dashed")
                                .font(.caption)
                                .foregroundStyle(Color.accentColor)
                        }
                        if isAccepted {
                            Label("Accepted", systemImage: "checkmark.circle.fill")
                                .font(.caption)
                                .foregroundStyle(Color.trajectoryTeal)
                        }
                    }
                }
                Spacer()
            }
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .overlay {
            if isSelected {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
            }
        }
        .background {
            if isAccepted {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.trajectoryTeal.opacity(0.12))
            }
        }
        .accessibilityLabel("\(answer.title). \(isSelected ? "Selected." : "") \(isAccepted ? "Accepted." : "")")
        .accessibilityHint("Selects this answer. Selecting never accepts.")
        .accessibilityIdentifier("answer-\(answer.rawValue)")
    }
}
