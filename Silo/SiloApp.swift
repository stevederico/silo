//
//  SiloApp.swift
//  Silo
//
//  Created by Steve Derico on 1/29/25.
//

import SwiftUI
import Foundation

@main
struct SiloApp: App {
    init() {
        // Disable ggml-metal residency sets (optimization for iOS 18+/macOS 15+ that can cause
        // crashes in ggml_metal_buffer_rset_init when mixing llama + whisper vendored frameworks
        // or on Simulator).
        //
        // We disable ONLY on Simulator for now (where Metal residency support is incomplete).
        // On real devices (iOS 18+), residency stays enabled for best Metal performance.
        //
        // If you still see rset_init crashes on device, force-disable by uncommenting the setenv below.
        #if targetEnvironment(simulator)
        setenv("GGML_METAL_NO_RESIDENCY", "1", 1)
        #endif

        // To always disable (for maximum compatibility):
        // setenv("GGML_METAL_NO_RESIDENCY", "1", 1)
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
