//
//  Walking_Buddy_WatchApp.swift
//  Walking Buddy Watch Watch App
//
//  Created by Logan Lee on 10/10/26.
//

import SwiftUI
import HealthKit
import WatchKit

/// Receives workout launches triggered from the iPhone via `startWatchApp(with:)`,
/// and starts a walk on the Watch so heart rate / energy begin streaming back.
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        guard !HealthKitManager.shared.isTracking else { return }
        HealthKitManager.shared.requestAuthorizationAndStart(fromRemote: true)
    }
}

@main
struct Walking_Buddy_Watch_Watch_AppApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var appDelegate
    // Activates the link to the iPhone early, so finished walks can be sent as soon as they end.
    init() { _ = WalkHistory.shared }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
