# Walking Buddy — setup status

All Xcode configuration is **complete**. Only on-device testing remains.
Shared App Group used everywhere: `group.Walking-Buddy.shared`

---

## ▶️ Remaining: test on real devices

Background location, Lock Screen widgets, and watch complications don't fully
work in the Simulator — verify on hardware:

- [ ] **Background monitoring** — on a real iPhone: Start a walk, lock the
      screen / background the app → monitoring keeps running (you'll see the
      location indicator). (Force-quitting still stops it — expected.)
- [ ] **iPhone Lock Screen widget** — long-press Lock Screen → Customize →
      add Walking Buddy (circular / rectangular / inline).
- [ ] **iPhone Home Screen widget** — long-press Home Screen → **+** →
      Walking Buddy → small.
- [ ] **Apple Watch** (real watch — the sim won't stream heart rate) —
      add the complication to a watch face and/or the Smart Stack.
- [ ] Confirm widgets show live numbers (not zeros). Zeros = App Group ID
      mismatch on a target.

---

## ✅ Completed

**Background monitoring (iPhone)**
- [x] Background Modes → Location updates (`UIBackgroundModes: location` in `Walking-Buddy-Info.plist`)
- [x] App Group capability
- [x] Location usage strings (When-In-Use + Always)

**Apple Watch complication + Smart Stack** (`Walking Buddy WidgetExtension`, watchOS)
- [x] Target created (embedded in Watch app)
- [x] Source: `Walking Buddy Widget/WalkingBuddyWatchWidget.swift` (circular / corner / inline + rectangular Smart Stack)
- [x] App Group capability
- [x] watchOS Deployment Target 10.0
- [x] RelevanceKit Smart Stack widget (`WalkingBuddySmartStackWidget`, watchOS 12+) — surfaces via a `.fitness(.workoutActive)` clue
- [x] HealthKit entitlement (`com.apple.developer.healthkit`) on the widget extension — **required** for the fitness relevance clue to fire
- [x] `NSHealthShareUsageDescription` added to `Walking Buddy Widget/Info.plist`
- [ ] **Verify in Xcode:** Signing & Capabilities for the `Walking Buddy WidgetExtension` target shows **HealthKit** (so automatic signing adds it to the provisioning profile). The entitlement is already in `Walking Buddy WidgetExtension.entitlements`.

**iPhone Lock + Home Screen widget** (`Walking Buddy iOS WidgetExtension`, iOS)
- [x] Target created (embedded in iPhone app)
- [x] Source: `Walking Buddy iOS Widget/WalkingBuddyWidget.swift` (circular / rectangular / inline + systemSmall)
- [x] App Group capability
- [x] iOS Deployment Target 16.6

**App-wide**
- [x] App Group `group.Walking-Buddy.shared` on all 4 targets
- [x] Health + Motion usage strings (iPhone + Watch)
- [x] New "buddy" logo (two figures + heart) on both app icons + in-app header
- [x] Deployment targets: iOS app 16.0, iOS widget 16.6, watch app + widget 10.0

---

## Reference — shared data keys

Written by `HealthKitManager.publishWidgetSnapshot()` into the App Group:
`wb.isTracking`, `wb.risk` (Int), `wb.steps`, `wb.distance`, `wb.time`,
`wb.updated`; watchOS also writes `wb.heartRate`, `wb.energy`.
