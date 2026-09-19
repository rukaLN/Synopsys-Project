import Foundation

#if canImport(UIKit)
import UIKit
#endif

#if canImport(CoreHaptics)
import CoreHaptics
#endif

#if canImport(WatchKit)
import WatchKit
#endif

struct HapticsManager {
    
    // MARK: - Core Haptics Engine
    
    #if canImport(CoreHaptics) && canImport(UIKit)
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
        #if canImport(UIKit)
        if #available(iOS 13.0, *) {
            // Pre-warm impact generator
            let impact = UIImpactFeedbackGenerator(style: .medium)
            impact.prepare()
            
            // Pre-warm notification generator
            let notification = UINotificationFeedbackGenerator()
            notification.prepare()
            
            #if canImport(CoreHaptics)
            // Warm up Core Haptics engine if available
            _ = engine
            #endif
        }
        #endif
        
        #if canImport(WatchKit)
        // Nothing to prepare for watchOS haptics
        #endif
    }
    
    // MARK: - Strong Alert
    
    static func strongAlert() {
        #if canImport(UIKit)
        if #available(iOS 13.0, *) {
            // Notification warning haptic
            let notification = UINotificationFeedbackGenerator()
            notification.notificationOccurred(.warning)
            
            // Play custom Core Haptics pattern (~1.8s)
            playStrongAlertPattern()
            return
        }
        #endif
        
        #if canImport(WatchKit)
        // On watchOS: play .failure then .retry after 0.6s
        let device = WKInterfaceDevice.current()
        device.play(.failure)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            device.play(.retry)
        }
        #endif
    }
    
    #if canImport(CoreHaptics) && canImport(UIKit)
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
