//
//  Walking_BuddyApp.swift
//  Walking Buddy
//
//  Created by Logan Lee on 7/29/26.
//

import SwiftUI

@main
struct Walking_BuddyApp: App {
    // Starts Apple Watch syncing at launch, including when the Watch wakes the app in the background.
    init() { _ = WalkHistory.shared }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
