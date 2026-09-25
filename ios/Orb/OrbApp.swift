import SwiftUI

@main
struct OrbApp: App {
    var body: some Scene {
        WindowGroup { ChatView(autoConnect: !ChatSession.previewMode) }
    }
}
