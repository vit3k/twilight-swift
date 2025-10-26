//
//  TwilightApp.swift
//  twilight
//
//  Created by Pawel Witkowski on 24/10/2025.
//

import Foundation
import AppKit

@main
struct TwilightApp {
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
            
            // Create Metal renderer (must be on main thread)
            guard let renderer = MetalRenderer(width: 2560, height: 1440, title: "Twilight Stream") else {
                print("Failed to create Metal renderer")
                exit(1)
            }
            
            // Connect decoder to renderer
            Decoder.shared.renderer = renderer
            
            // Start streaming in background
            let moonlightClient = MoonlightClient()
            moonlightClient.startStreaming(launchInfo: launchInfo, serverInfo: serverInfo)
            
            // Capture mouse for gaming (optional - you can also press Cmd+M to toggle)
            renderer.captureMouse()
            
            // Run render loop on main thread
            print("Streaming started. Press ESC to release mouse, ESC again to exit. Cmd+M to toggle mouse capture.")
            while renderer.processEvents() {
                // Process events continuously
                // This must be called from the main thread
            }
            
            print("Renderer closed. Exiting.")
            exit(0)
            
        } catch {
            print("Failed to launch app: \(error)")
            exit(1)
        }

    }
}
