import AppKit
import UniformTypeIdentifiers
import WallpaperCore
import WallpaperEditorCore

extension EditorApplicationDelegate {
    @objc func importModel() { active?.importModel() }
}

extension EditorWindowController {
    func importModel() {
        perform { controller in
            // Flush valid Model/Timeline fields and surface their errors before granting a file selection.
            _ = try await controller.snapshot()
            guard let gltf = UTType(filenameExtension: "gltf"), let glb = UTType(filenameExtension: "glb") else {
                throw WallpaperError("Cannot resolve glTF file types.")
            }
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [gltf, glb]
            panel.canChooseFiles = true; panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false; panel.allowsOtherFileTypes = false
            panel.title = text("importModel")
            guard panel.runModal() == .OK, let url = panel.url else { return }
            let source = try EditorModelImportSource(url: url)
            _ = try await controller.command(["type": "import-model", "source": source.commandSource])
        }
    }
}
