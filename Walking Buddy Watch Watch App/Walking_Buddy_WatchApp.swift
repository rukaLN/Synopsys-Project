//
//  Walking_Buddy_WatchApp.swift
//  Walking Buddy Watch Watch App
//
//  Created by Logan Lee on 10/10/26.
//

import SwiftUI

@main
struct Walking_Buddy_Watch_Watch_AppApp: App {
    // Activates the link to the iPhone early, so finished walks can be sent as soon as they end.
    init() { _ = WalkHistory.shared }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
