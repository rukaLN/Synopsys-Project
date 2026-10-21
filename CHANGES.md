# Walking Buddy — change log

Everything added/changed recently, in one place. Branch: **New-main**
(HEAD `333b7fc "Graph"`). All targets build green.

---

## 1. Design & branding
- **Minimalist sporty redesign** of the iPhone `ContentView` — status pill, animated
  **break-risk ring** (green→orange→red), metric cards grid, gradient action button.
  Reusable pieces: `Theme`, `WalkingBuddyLogo`, `StatusPill`, `RiskRing`, `MetricCard`.
- **New "buddy" logo** — two walking figures (white + amber) with a heart, on the
  green→teal gradient. Applied to both app icons (iPhone + Watch) and the in-app header.
- Matching Watch UI refresh (compact risk ring, brand accents).
- Fixed the `NSMotionUsageDescription` empty-string warning on the Watch target.

## 2. Background monitoring (iPhone)
- `HealthKitManager` runs a low-power **CoreLocation keep-alive** so the risk timer,
  pedometer, and break alerts keep running with the screen off / app backgrounded.
- Capability: Background Modes → Location updates (`UIBackgroundModes: location` in
  `Walking-Buddy-Info.plist`) + Location usage strings. (Force-quitting still stops it.)

## 2a. Always-location nudge (only during a workout)
- Location is requested/used **only when a walk starts** (and stops on Stop).
- On Start we request **Always**; if the user is on "While Using" / Denied, the Monitor
  screen shows a banner explaining why Always is needed, tapping through to Settings.
- `locationManagerDidChangeAuthorization` turns on background updates the moment the
  user upgrades to Always. (iOS always offers "While Using" in its own prompt — that
  can't be removed — so the banner is how we steer users to Always.)

## 2b. Interruption resilience (calls)
- A FaceTime/phone call could stall `CMMotionManager` / the live pedometer, and they
  don't auto-resume — tracking froze until the call ended. `HealthKitManager` now
  re-primes the sensors on `UIApplication.didBecomeActive` during a walk and backfills
  the pedometer from the original start date, so a call no longer freezes tracking.

## 3. Real-time gait analysis — `GaitAnalyzer.swift`
- Reads device motion at ~50 Hz and derives **live** estimates (HealthKit gait metrics
  are passive/frozen during a walk):
  - **Cadence** from step-interval detection (gravity-projected, pocket-friendly).
  - **Steadiness** from step-time variability.
  - **Asymmetry** from alternating (left/right) step intervals.
  - **Double-support** proxy from stance-phase fraction.
  - **Step length** = speed ÷ cadence.
- Feeds the break-risk equation on every update, so values and risk respond in ~1–2 s.
- iOS-only; the Simulator has no IMU, so it falls back to the simulated walker.

## 4. Break-risk model + sustained-dwell alarm — `BreakRiskModel.swift`
- Sensitivity bump: `steadinessFloor` 0.5→0.6, `breakThreshold` 0.5→0.45.
- **Sustained-dwell alarm equation** — a metric must stay tripped continuously
  for **H = 3 s** before it alerts:
  - `Iₘ(t) = [sₘ(t) ≥ τ]`, `Dₘ(t) = t − last instant Iₘ=0`,
    `Aₘ(t) = [Iₘ=1 ∧ Dₘ ≥ H]`, overall `A = (⋁ₘ Aₘ) ∧ [steps ≥ Nₘᵢₙ]`.
  - τ = `tripThreshold` (0.5), H = `sustainedHoldDuration` (3 s). Timers reset on
    recovery, start, stop, and pause. Alert names the exact metric(s) that held.
- **Rest flow:** tapping "I am sitting" on the break alert now **pauses** the walk
  (keeps elapsed time/stats); the screen then offers **Resume** or **Stop**. The status
  pill shows "Paused — Resting". Works on both iPhone and Apple Watch.

## 5. Widgets
- **iPhone widget** (`Walking Buddy iOS Widget/WalkingBuddyWidget.swift`) — Lock Screen
  (circular / rectangular / inline) + Home Screen (small).
- **Apple Watch widget** (`Walking Buddy Widget/WalkingBuddyWatchWidget.swift`) —
  face complications (circular / corner / inline) + Smart Stack (rectangular).
- **Data bridge**: `HealthKitManager.publishWidgetSnapshot()` writes live metrics to the
  shared App Group `group.Walking-Buddy.shared` and reloads WidgetKit. Keys: `wb.risk`,
  `wb.steps`, `wb.distance`, `wb.time`, `wb.isTracking` (+ `wb.heartRate`, `wb.energy` on watch).
- App Group enabled on all four targets.

## 6. Live Activity (the "Spotify-style" Lock Screen card)
- `WalkActivityAttributes.swift` (shared) + `WalkLiveActivity.swift` (in the iOS widget
  extension) — a live card on the **Lock Screen + Dynamic Island** while a walk runs,
  showing risk, steps, distance, time; updates live and ends on Stop.
- `HealthKitManager` starts/updates/ends the activity (iOS 16.2+). `NSSupportsLiveActivities`
  added to the app Info.plist.

## 7. History & trend graph (phone — added by partner; watch — added here)
- **iPhone History tab** — `ContentView` is now a `TabView` (Monitor + History);
  `HistoryView.swift` draws a **Swift Charts** graph of metric trends across past walks.
- **Apple Watch history page** — `WatchHistoryView.swift`; the watch `ContentView` is now
  a vertical-page `TabView` (Monitor + History) with a Swift Charts trend of a chosen
  metric (risk / steadiness / cadence / heart rate) across recent walks.
- `WalkHistory.swift` — persists completed walks and **syncs watch → iPhone** over
  WatchConnectivity; `WalkTrends.swift` — trend series (phone).
- `HealthKitManager` additions: `WalkRecorder` (saves each walk on Stop), a
  "notifications are off" banner, and idle / stopped-walking detection.

> Note: the iPhone holds the complete history (its own walks + synced watch walks);
> the watch page shows walks finished on the watch.

---

## New files
```
Walking Buddy/GaitAnalyzer.swift
Walking Buddy/WalkActivityAttributes.swift
Walking Buddy/HistoryView.swift
Walking Buddy/WalkHistory.swift
Walking Buddy/WalkTrends.swift
Walking Buddy iOS Widget/WalkingBuddyWidget.swift
Walking Buddy iOS Widget/WalkLiveActivity.swift
Walking Buddy Widget/WalkingBuddyWatchWidget.swift
Walking-Buddy-Info.plist
SETUP.md        (Xcode setup checklist — all complete; device-test list at top)
CHANGES.md      (this file)
```

## Status
- All Xcode setup complete (widgets, App Groups, background mode, usage strings).
- Remaining: **device testing** (background location + widgets + Live Activity need real
  hardware — see `SETUP.md`).
- Committed locally on `New-main`; push via GitHub Desktop when ready.
