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

## 7. History & trend graph (added by partner — merged in)
- **History tab** — `ContentView` is now a `TabView` (Monitor + History).
- `HistoryView.swift` — **Swift Charts** graph of metric trends across past walks.
- `WalkHistory.swift` — persists completed walks; `WalkTrends.swift` — trend series.
- `HealthKitManager` additions: `WalkRecorder` (saves each walk on Stop), a
  "notifications are off" banner, and idle / stopped-walking detection.

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
