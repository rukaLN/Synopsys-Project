import Foundation

#if os(iOS)
import UIKit
import CoreHaptics
#endif

#if os(watchOS)
import WatchKit
#endif

struct HapticsManager {

    // MARK: - Core Haptics Engine

    #if os(iOS)
    private static var engine: CHHapticEngine? = {
        do {
            let engine = try CHHapticEngine()
            try engine.start()
            return engine
        } catch {
            return nil
        }
    }()
    #endif
    
    // MARK: - Prepare
    
    static func prepare() {
        #if os(iOS)
        // Pre-warm the impact and notification generators.
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.prepare()

        let notification = UINotificationFeedbackGenerator()
        notification.prepare()

        // Warm up the Core Haptics engine.
        _ = engine
        #endif

        // Nothing to prepare for watchOS haptics.
    }
    
    // MARK: - Strong Alert
    
    static func strongAlert() {
        #if os(iOS)
        // Notification warning haptic.
        let notification = UINotificationFeedbackGenerator()
        notification.notificationOccurred(.warning)

        // Play custom Core Haptics pattern (~1.8s).
        playStrongAlertPattern()
        #elseif os(watchOS)
        // On watchOS: play .failure then .retry after 0.6s.
        let device = WKInterfaceDevice.current()
        device.play(.failure)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            device.play(.retry)
        }
        #endif
    }

    #if os(iOS)
    private static func playStrongAlertPattern() {
        guard let engine = engine else { return }
        
        // Core Haptics pattern JSON approximation:
        // - Alternating strong transient events with intensity 1.0, sharpness 0.8
        // - 1.8 seconds total duration with some brief pauses
        
        let events: [CHHapticEvent] = [
            .init(eventType: .hapticTransient,
                  parameters: [
                    .init(parameterID: .hapticIntensity, value: 1.0),
                    .init(parameterID: .hapticSharpness, value: 0.8)
                  ],
                  relativeTime: 0.0),
            
            .init(eventType: .hapticTransient,
                  parameters: [
                    .init(parameterID: .hapticIntensity, value: 1.0),
                    .init(parameterID: .hapticSharpness, value: 0.8)
                  ],
                  relativeTime: 0.4),
            
            .init(eventType: .hapticTransient,
                  parameters: [
                    .init(parameterID: .hapticIntensity, value: 1.0),
                    .init(parameterID: .hapticSharpness, value: 0.8)
                  ],
                  relativeTime: 0.8),
            
            .init(eventType: .hapticTransient,
                  parameters: [
                    .init(parameterID: .hapticIntensity, value: 1.0),
                    .init(parameterID: .hapticSharpness, value: 0.8)
                  ],
                  relativeTime: 1.2)
        ]
        
        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try engine.makePlayer(with: pattern)
            try player.start(atTime: 0)
        } catch {
            // silently fail if haptics pattern playback fails
        }
    }
    #endif
}
