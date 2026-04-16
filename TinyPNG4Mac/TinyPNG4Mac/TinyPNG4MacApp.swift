//
//  TinyPNG4MacApp.swift
//  TinyPNG4Mac
//
//  Created by kyleduo on 2024/11/16.
//

import SwiftData
import SwiftUI

@main
struct TinyPNG4MacApp: App {
    @Environment(\.openWindow) private var openWindow

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelgate
    @StateObject var appContext = AppContext.shared
    @StateObject var vm: MainViewModel = MainViewModel()
    @StateObject var debugVM: DebugViewModel = DebugViewModel.shared

    @State var firstAppear: Bool = true
    @State var lastTaskCount = 0

    var body: some Scene {
        Window("Tiny Image", id: "main") {
            MainContentView(vm: vm)
                .frame(
                    minWidth: appContext.minSize.width,
                    idealWidth: appContext.minSize.width,
                    maxWidth: appContext.maxSize.width,
                    minHeight: appContext.minSize.height,
                    idealHeight: appContext.minSize.height
                )
                .onAppear {
                    if !firstAppear {
                        return
                    }
                    firstAppear = false

                    appDelgate.configure(viewModel: vm) {
                        openWindow(id: "main")
                    }
                }
                .environmentObject(appContext)
                .environmentObject(debugVM)
        }
        .windowStyle(HiddenTitleBarWindowStyle())
        .windowResizability(.contentSize)
        .defaultSize(appContext.minSize)
        .commands {
            CommandGroup(replacing: CommandGroupPlacement.appInfo) {
                Button(action: {
                    // Open the "about" window
                    openWindow(id: "about")
                }, label: {
                    Text("About...")
                })
            }
        }

        // Note the id "about" here
        Window("About Tiny Image", id: "about") {
            AboutView()
        }
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView()
        }
    }

    func animateWindowFrame(_ window: NSWindow, newFrame: NSRect) {
        let animation = NSViewAnimation()
        animation.viewAnimations = [
            [
                NSViewAnimation.Key.target: window,
                NSViewAnimation.Key.startFrame: NSValue(rect: window.frame),
                NSViewAnimation.Key.endFrame: NSValue(rect: newFrame),
            ],
        ]
        animation.duration = 0.3
        animation.animationCurve = .easeOut
        animation.start()
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private struct PendingOpenRequest {
        let urls: [URL]
        let saveMode: String?
        let outputDirectoryUrl: URL?
    }

    private var vm: MainViewModel?
    private var openMainWindow: (() -> Void)?

    private var pendingOpenRequests: [PendingOpenRequest] = []
    private var appDidFinishLaunching = false

    func configure(viewModel vm: MainViewModel, openMainWindow: @escaping () -> Void) {
        if self.vm == nil {
            self.vm = vm
        }
        self.openMainWindow = openMainWindow

        tryHandleOpenUrls()
    }

    @objc(compressSelection:userData:error:)
    func compressSelection(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handleServiceRequest(
            pasteboard,
            saveMode: AppConfig.saveModeNameOverwrite,
            requiresOutputDirectorySelection: false,
            error: error
        )
    }

    @objc(compressSelectionSaveAs:userData:error:)
    func compressSelectionSaveAs(_ pasteboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        handleServiceRequest(
            pasteboard,
            saveMode: AppConfig.saveModeNameSaveAs,
            requiresOutputDirectorySelection: true,
            error: error
        )
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        FileUtils.initPaths()

        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        if let window = NSApp.windows.first {
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
        }

        appDidFinishLaunching = true

        tryHandleOpenUrls()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        enqueueOpenUrls(urls, bringAppToFront: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let vm = vm else {
            return .terminateNow
        }

        if !vm.shouldTerminate() {
            vm.showRunnningTasksAlert()
            return .terminateCancel
        } else {
            return .terminateNow
        }
    }

    private func tryHandleOpenUrls() {
        guard appDidFinishLaunching, let vm, !pendingOpenRequests.isEmpty else {
            return
        }

        let requests = pendingOpenRequests
        pendingOpenRequests.removeAll()

        for request in requests {
            let imageUrls = FileUtils.findImageFiles(urls: request.urls)
            if !imageUrls.isEmpty {
                vm.createTasks(
                    imageURLs: imageUrls,
                    saveMode: request.saveMode,
                    outputDirectoryUrl: request.outputDirectoryUrl
                )
            }
        }
    }

    private func enqueueOpenUrls(
        _ urls: [URL],
        saveMode: String? = nil,
        outputDirectoryUrl: URL? = nil,
        bringAppToFront: Bool
    ) {
        guard !urls.isEmpty else {
            return
        }

        var uniqueUrls: [URL] = []
        for url in urls {
            if !uniqueUrls.contains(where: { $0.isSameFilePath(as: url) }) {
                uniqueUrls.append(url.standardizedFileURL)
            }
        }

        pendingOpenRequests.append(
            PendingOpenRequest(
                urls: uniqueUrls,
                saveMode: saveMode,
                outputDirectoryUrl: outputDirectoryUrl
            )
        )

        DispatchQueue.main.async {
            if bringAppToFront {
                self.openMainWindow?()
                NSApp.activate(ignoringOtherApps: true)
                NSApp.windows.first?.makeKeyAndOrderFront(nil)
            }

            self.tryHandleOpenUrls()
        }
    }

    private func handleServiceRequest(
        _ pasteboard: NSPasteboard,
        saveMode: String,
        requiresOutputDirectorySelection: Bool,
        error: AutoreleasingUnsafeMutablePointer<NSString?>
    ) {
        let urls = extractFileUrls(from: pasteboard)
        if urls.isEmpty {
            error.pointee = "No valid files were provided to Tiny Image." as NSString
            return
        }

        let outputDirectoryUrl: URL?
        if requiresOutputDirectorySelection {
            guard let selectedDirectory = selectServiceOutputDirectory() else {
                return
            }
            outputDirectoryUrl = selectedDirectory
        } else {
            outputDirectoryUrl = nil
        }

        enqueueOpenUrls(
            urls,
            saveMode: saveMode,
            outputDirectoryUrl: outputDirectoryUrl,
            bringAppToFront: true
        )
    }

    private func extractFileUrls(from pasteboard: NSPasteboard) -> [URL] {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [
            .urlReadingFileURLsOnly: true,
        ]
        return (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL])?
            .map(\.standardizedFileURL) ?? []
    }

    private func selectServiceOutputDirectory() -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.directoryURL = AppContext.shared.appConfig.outputDirectoryUrl ??
            FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.title = String(localized: "Select output directory")
        panel.prompt = String(localized: "Select")

        NSApp.activate(ignoringOtherApps: true)

        guard panel.runModal() == .OK else {
            return nil
        }

        return panel.url?.standardizedFileURL
    }
}
