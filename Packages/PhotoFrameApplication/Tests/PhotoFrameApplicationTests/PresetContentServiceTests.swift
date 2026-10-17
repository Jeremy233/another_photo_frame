import Foundation
import PhotoFrameApplication
import PhotoFrameCore
import Testing

@Suite struct PresetContentServiceTests {
    @Test func saveAndReplacePreset() async throws {
        let box = try Sandbox()
        let service = try LocalPhotoFrameService.makeDefault(.init(libraryRoot: box.root.appending(path: "Library")))
        let builtIn = try await service.resolvePreset(.library("instagram-standard")).preset
        var content = builtIn
        content.canvas.minMarginPx = 80

        let saved = try await service.savePreset(content, name: "My IG")
        #expect(saved.presetId != builtIn.presetId)
        #expect(saved.origin == .user && saved.minMarginPx == 80)

        var edited = try await service.resolvePreset(.library(saved.presetId.uuidString)).preset
        edited.canvas.minMarginPx = 120
        let replaced = try await service.replacePreset(edited)
        #expect(replaced.minMarginPx == 120 && replaced.name == "My IG")

        await #expect(throws: ApplicationError.self) { try await service.replacePreset(builtIn) }
        #expect(await service.assetContentURL(UUID()) == nil)
    }
}
