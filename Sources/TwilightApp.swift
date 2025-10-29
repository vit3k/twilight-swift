//
//  TwilightApp.swift
//  twilight
//
//  Created by Pawel Witkowski on 24/10/2025.
//

import AppKit
import Foundation

@main
struct TwilightApp {
    @MainActor
    static func main() async {
        // Resolve client.p12 relative to current working directory for this example
        let cwd = FileManager.default.currentDirectoryPath
        let p12Relative = "client.p12"
        let p12Path = URL(fileURLWithPath: p12Relative, relativeTo: URL(fileURLWithPath: cwd)).path
        let p12Password = "123456"

        // Initialize the client with shared host/port and your uniqueId
        guard
            let client = SunshineClient(
                p12Path: p12Path,
                password: p12Password,
                scheme: "https",
                host: "192.168.10.103",
                port: 47984,
                uniqueId: "123456789ABCDEF")
        else {
            print("Could not initialize client (failed to load PKCS#12). Exiting.")
            exit(1)
        }

        do {
            let serverInfo = try await client.getServerInfo()
            print("Server info: \(serverInfo)")
            let launchInfo = try await client.launchApp(appId: 881_448_767)
            print("Launch Info: \(launchInfo)")

            // Create window manager and metal renderer (must be on main thread)
            guard
                let windowManager = WindowManager(
                    width: 2560, height: 1440, title: "Twilight Stream")
            else {
                print("Failed to create window manager")
                exit(1)
            }

            guard let metalRenderer = MetalRenderer(width: 2560, height: 1440)
            else {
                print("Failed to create metal renderer")
                exit(1)
            }

            // Replace the window's metal layer with the renderer's layer
            if let view = windowManager.window.contentView {
                view.layer = metalRenderer.metalLayer
            }

            // Connect decoder to metal renderer
            Decoder.shared.metalRenderer = metalRenderer

            // Start streaming in background
            let moonlightClient = MoonlightClient()
            moonlightClient.startStreaming(launchInfo: launchInfo, serverInfo: serverInfo)

            // Capture mouse for gaming (optional - you can also press Cmd+M to toggle)
            windowManager.captureMouseAndKeyboard()

            // Run render loop on main thread
            print(
                "Streaming started. Press Shift+Ctrl+Option+M to toggle mouse capture, Shift+Ctrl+Option+Q to quit."
            )
            while windowManager.processEvents() {
                // Process all queued frames
                metalRenderer.processFrames()
            }

            print("Renderer closed. Exiting.")
            exit(0)

        } catch {
            print("Failed to launch app: \(error)")
            exit(1)
        }

    }
}
