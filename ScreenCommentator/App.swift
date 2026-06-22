import SwiftUI
import AppKit

@main
struct ScreenCommentatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var viewModel = CommentViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(viewModel)
                .onAppear {
                    appDelegate.showOverlay(viewModel: viewModel)
                }
        }
        .windowResizability(.contentSize)
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let overlayController = OverlayWindowController()

    @MainActor
    func showOverlay(viewModel: CommentViewModel) {
        overlayController.show(viewModel: viewModel)
    }

    func applicationWillTerminate(_ notification: Notification) {
        Task { @MainActor in
            overlayController.close()
        }
    }
}
