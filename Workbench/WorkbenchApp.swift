import SwiftUI
import WorkbenchCore

@main
struct WorkbenchApp: App {
    @State private var model = WorkbenchModel()

    var body: some Scene {
        WindowGroup {
            WorkbenchRoot(model: model)
        }
    }
}
