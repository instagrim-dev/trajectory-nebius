import SwiftUI
import WorkbenchCore

/// Consequence preview for the selected-but-unaccepted answer.
/// Read-only by construction: no accept or execute control exists here.
struct PreviewSheet: View {
    var model: WorkbenchModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(model.scope(for: model.state.selected))
                        .font(.body)
                    LabeledContent("Baseline", value: "Saved \(model.state.viewed.versionLabel) reopens unchanged")
                } header: {
                    Text("Scope of the selected answer")
                }
                Section {
                    ForEach(model.previewCases, id: \.self) { text in
                        Text(text).font(.body)
                    }
                } header: {
                    Text("Authored cases")
                }
                Section {
                    Text("\(model.requiredChecks.count) required checks · 0 executed")
                        .font(.body)
                    Text(model.requiredChecks.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("Checks")
                } footer: {
                    Text("Preview only — nothing accepted, constructed, or checked.")
                }
            }
            .navigationTitle("Preview")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("preview-close")
                }
            }
        }
    }
}

/// One-file-at-a-time comparison of the two saved programs.
/// Read-only: compare changes nothing.
struct CompareView: View {
    var model: WorkbenchModel
    @Environment(\.dismiss) private var dismiss
    @State private var selectedFile = "queue.go"

    private var file: WorkbenchModel.FileSample {
        model.files.first(where: { $0.name == selectedFile }) ?? model.files[0]
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("File", selection: $selectedFile) {
                        ForEach(model.files.map(\.name), id: \.self) { name in
                            Text(name).tag(name)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("File to compare")
                    .accessibilityIdentifier("compare-file-picker")
                }
                Section {
                    CompareSide(
                        title: "v1 · request-time",
                        identity: SampleProgram.v1.sourceIdentityPrefix,
                        note: file.v1Note,
                        observation: model.observationLine(for: .v1)
                    )
                    CompareSide(
                        title: "v2 · delivery-time",
                        identity: SampleProgram.v2.sourceIdentityPrefix,
                        note: file.v2Note,
                        observation: model.observationLine(for: .v2)
                    )
                } header: {
                    Text("Sides")
                }
                Section {
                    if let diff = file.diff {
                        ScrollView(.horizontal) {
                            Text(diff)
                                .font(.system(size: 13, design: .monospaced))
                                .padding(8)
                        }
                    } else {
                        Text("\(file.name) is unchanged between v1 and v2.")
                            .font(.body)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Change")
                } footer: {
                    Text("Compare changes nothing — no selection, acceptance, construction, or check.")
                }
            }
            .navigationTitle("Compare")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }
                        .accessibilityIdentifier("compare-close")
                }
            }
        }
    }
}

private struct CompareSide: View {
    var title: String
    var identity: String
    var note: String
    var observation: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.headline)
            Text(identity).font(.body.monospaced()).foregroundStyle(.secondary)
            Text(note).font(.body)
            Text(observation).font(.caption).foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
