//
//  WalkActivityAttributes.swift
//  Walking Buddy
//
//  Shared Live Activity model. This file MUST be a member of BOTH the main app
//  target and the "Walking Buddy iOS WidgetExtension" target — the Live Activity
//  system matches the app's `Activity<WalkActivityAttributes>` to the widget's
//  `ActivityConfiguration(for: WalkActivityAttributes.self)` by type identity,
//  so they have to compile the same type from this one file.
//
//  (In Xcode: select this file → File Inspector → Target Membership → also
//  check "Walking Buddy iOS WidgetExtension".)
//

import ActivityKit

@available(iOS 16.1, *)
struct WalkActivityAttributes: ActivityAttributes {
    /// Live, changing values shown on the Lock Screen / Dynamic Island.
    public struct ContentState: Codable, Hashable {
        var risk: Int
        var steps: String
        var distance: String
        var time: String
    }

    /// Static value for the duration of the activity.
    var title: String = "Walking Buddy"
}
