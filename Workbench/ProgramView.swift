import SwiftUI
import WorkbenchCore

/// Saved-program detail: source and retained result for the viewed
/// program. Reopening is cheap and never changes accepted intent.
/// Construction and live checks are unavailable in this sample.
struct ProgramView: View {
    var model: WorkbenchModel
    var program: SampleProgram

    var body: some View {
        List {
            Section {
                LabeledContent("Version", value: program.versionLabel)
                LabeledContent("Answer", value: program.answer.title)
                LabeledContent("Source identity", value: program.sourceIdentityPrefix)
                    .font(.body.monospaced())
            } header: {
                Text("Source")
            }
            Section {
                ForEach(model.files, id: \.name) { file in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(file.name)
                            .font(.body.monospaced())
                        Text(program == .v1 ? file.v1Note : file.v2Note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        ScrollView(.horizontal) {
                            Text(program == .v1 ? file.v1Excerpt : file.v2Excerpt)
                                .font(.system(size: 13, design: .monospaced))
                                .padding(8)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } header: {
                Text("Files (retained fixture excerpts)")
            }
            Section {
                Text(model.observationLine(for: program))
                    .font(.body)
                Text(model.scenarioLine(for: program))
                    .font(.body)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Retained result")
            } footer: {
                Text("Saved program — reopened for viewing only. Construction and live checks are not part of this sample.")
            }
        }
        .navigationTitle("Program \(program.rawValue)")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { model.openProgram(program) }
    }
}
