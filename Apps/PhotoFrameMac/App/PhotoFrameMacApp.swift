import PhotoFrameMacUI
import SwiftUI

@main
struct PhotoFrameMacApp: App {
    @NSApplicationDelegateAdaptor(PhotoFrameAppDelegate.self) private var delegate

    var body: some Scene {
        PhotoFrameScene()
    }
}
