//
//  AppSettings.swift
//  YTRun
//

import Foundation
import Combine

// `ObservableObject` + `@Published` is SwiftUI's way of exposing mutable
// state that views should automatically re-render in response to.
// Any view that holds this as `@StateObject`/`@EnvironmentObject` and
// reads `dailyLimitMinutes`/`bingeLimitMinutes` will refresh whenever
// they change.
//
// We back each property with UserDefaults so values survive app restarts.
// UserDefaults is a simple key-value plist store — fine for small settings
// like this; not meant for large data.
final class AppSettings: ObservableObject {
    private enum Keys {
        static let dailyLimitMinutes = "dailyLimitMinutes"
        static let bingeLimitMinutes = "bingeLimitMinutes"
        static let cooldownMinutes = "cooldownMinutes"
        static let bingeResetAfterMinutes = "bingeResetAfterMinutes"
        static let minutesPerRun = "minutesPerRun"
        static let qualifyingDistanceKm = "qualifyingDistanceKm"
        static let qualifyingDurationMinutes = "qualifyingDurationMinutes"
        static let weightKg = "weightKg"
        static let carBluetoothDeviceName = "carBluetoothDeviceName"
        static let restrictShorts = "restrictShorts"
        static let listenModeEnabled = "listenModeEnabled"
        static let enableSimulateRun = "enableSimulateRun"
        static let listenRatePercent = "listenRatePercent"
        static let carRatePercent = "carRatePercent"
        static let aiGatewayURI = "aiGatewayURI"
        static let aiGatewayClientID = "aiGatewayClientID"
        static let aiGatewayClientSecret = "aiGatewayClientSecret"
        static let aiGatewayToken = "aiGatewayToken"
        static let chatGPTShortcutName = "chatGPTShortcutName"
        static let enableWalkOption = "enableWalkOption"
        static let walkAllowsVideo = "walkAllowsVideo"
        static let enablePushUpOption = "enablePushUpOption"
        static let enableSitUpOption = "enableSitUpOption"
        static let enableLungeOption = "enableLungeOption"
        static let repsPerExerciseSet = "repsPerExerciseSet"
        static let secondsPerExerciseSet = "secondsPerExerciseSet"
        static let enableStairsOption = "enableStairsOption"
        static let floorsPerStairSet = "floorsPerStairSet"
        static let secondsPerStairSet = "secondsPerStairSet"
    }

    private enum Defaults {
        static let dailyLimitMinutes = 60
        static let bingeLimitMinutes = 20
        // Defaults to double the binge limit, per the original ask — but
        // stored as its own independent setting rather than always being
        // recomputed, so changing one later doesn't silently change the
        // other.
        static let cooldownMinutes = 40
        // How long a break has to be before a *partial* binge session
        // (one that never actually hit the limit) forgives itself.
        static let bingeResetAfterMinutes = 30
        static let minutesPerRun = 20
        static let qualifyingDistanceKm = 5.0
        static let qualifyingDurationMinutes = 30
        static let weightKg = 70.0
        // Both expressed as "% of a real second that counts toward the
        // daily/binge totals" — e.g. 50 means 10 real minutes of listening
        // only uses up 5 minutes of allowance. View (foreground) is always
        // 100% and isn't configurable.
        static let listenRatePercent = 50
        static let carRatePercent = 10
        static let chatGPTShortcutName = "YTRun Summarize"
        static let repsPerExerciseSet = 5
        static let secondsPerExerciseSet = 120
        static let floorsPerStairSet = 2
        static let secondsPerStairSet = 120
    }

    @Published var dailyLimitMinutes: Int {
        didSet { UserDefaults.standard.set(dailyLimitMinutes, forKey: Keys.dailyLimitMinutes) }
    }

    // Cumulative minutes you can watch (pauses don't reset this) before
    // being locked out for a cooldown — see `UsageTracker`.
    @Published var bingeLimitMinutes: Int {
        didSet { UserDefaults.standard.set(bingeLimitMinutes, forKey: Keys.bingeLimitMinutes) }
    }

    // How long the lockout lasts once the binge limit is hit. Must fully
    // elapse — nothing shortens it, including a run.
    @Published var cooldownMinutes: Int {
        didSet { UserDefaults.standard.set(cooldownMinutes, forKey: Keys.cooldownMinutes) }
    }

    // If you go this long without watching anything, the binge counter
    // forgives itself and resets to 0 — even if you never actually hit
    // the binge limit. Without this, a *partial* binge session (say 17 of
    // a 20-minute limit) would otherwise sit there indefinitely, since
    // only fully hitting the limit (→ cooldown → reset) or a run ever
    // clears it.
    @Published var bingeResetAfterMinutes: Int {
        didSet { UserDefaults.standard.set(bingeResetAfterMinutes, forKey: Keys.bingeResetAfterMinutes) }
    }

    @Published var minutesPerRun: Int {
        didSet { UserDefaults.standard.set(minutesPerRun, forKey: Keys.minutesPerRun) }
    }

    // A run qualifies for the reward if it meets *either* of these — see
    // `RunTracker`/`RunView`.
    @Published var qualifyingDistanceKm: Double {
        didSet { UserDefaults.standard.set(qualifyingDistanceKm, forKey: Keys.qualifyingDistanceKm) }
    }

    @Published var qualifyingDurationMinutes: Int {
        didSet { UserDefaults.standard.set(qualifyingDurationMinutes, forKey: Keys.qualifyingDurationMinutes) }
    }

    // Used only for a rough calorie estimate on saved runs (no HealthKit,
    // no heart rate — just distance × weight, so treat it as approximate).
    @Published var weightKg: Double {
        didSet { UserDefaults.standard.set(weightKg, forKey: Keys.weightKg) }
    }

    // Used to recognize "Car" as a distinct listening category in Daily
    // History. CarPlay connections are detected automatically (a distinct
    // AVAudioSession port type); a plain Bluetooth pairing to a car
    // stereo looks identical to Bluetooth headphones to iOS, so this lets
    // you name your car's Bluetooth device to match on instead. Matched
    // case-insensitively as a substring — e.g. "BYD" matches "BYD Auto".
    @Published var carBluetoothDeviceName: String {
        didSet { UserDefaults.standard.set(carBluetoothDeviceName, forKey: Keys.carBluetoothDeviceName) }
    }

    // When on, Shorts are hidden outright (thumbnails, shelves, the Shorts
    // tab) so they can't be previewed, and any direct navigation to a
    // Shorts page (`/shorts/...`) redirects back to the home feed instead
    // of playing — see `YouTubeWebViewStore`.
    @Published var restrictShorts: Bool {
        didSet { UserDefaults.standard.set(restrictShorts, forKey: Keys.restrictShorts) }
    }

    // Toggled from the YouTube screen itself (not just Settings) — forces
    // the lowest video quality and covers the player so no video frames
    // are visible, while audio keeps playing normally. Persisted so it
    // carries over between visits, same as every other setting here.
    @Published var listenModeEnabled: Bool {
        didSet { UserDefaults.standard.set(listenModeEnabled, forKey: Keys.listenModeEnabled) }
    }

    // Off by default. When off, the Locked screen's "Simulate Run"
    // button (which grants the run reward with no actual GPS/distance/
    // duration check at all) doesn't show at all — see `LockedView`.
    // The whole point of the app is the running requirement, so an
    // always-visible one-tap bypass right there on the Locked screen
    // undermined that; this setting exists for legitimately testing the
    // reward flow, deliberately requiring a trip to Settings first
    // rather than being a tap away in the moment you're trying to
    // resist bypassing the limit.
    @Published var enableSimulateRun: Bool {
        didSet { UserDefaults.standard.set(enableSimulateRun, forKey: Keys.enableSimulateRun) }
    }

    // How much of a real second of background listening counts toward
    // the daily/binge totals — see `UsageTracker.recordTick`. 50 means
    // watching in the background costs half as much allowance as
    // actually looking at the screen.
    @Published var listenRatePercent: Int {
        didSet { UserDefaults.standard.set(listenRatePercent, forKey: Keys.listenRatePercent) }
    }

    // Same idea as `listenRatePercent`, but for audio routed to a car
    // (CarPlay or a matched Bluetooth car stereo) — usually set lower
    // than the listen rate, since car listening is the most "passive"
    // mode.
    @Published var carRatePercent: Int {
        didSet { UserDefaults.standard.set(carRatePercent, forKey: Keys.carRatePercent) }
    }

    // Base URL of a self-hosted ai-gateway instance (see that project's
    // own README) — e.g. "https://your-host.ts.net/gateway". Used by
    // the YouTube screen's "Summarize" feature. Stored the same way as
    // every other setting here (plain UserDefaults, not Keychain) —
    // consistent with the gateway's own server-side config, which is
    // equally plaintext-on-disk for this personal, single-user setup.
    @Published var aiGatewayURI: String {
        didSet { UserDefaults.standard.set(aiGatewayURI, forKey: Keys.aiGatewayURI) }
    }

    @Published var aiGatewayClientID: String {
        didSet { UserDefaults.standard.set(aiGatewayClientID, forKey: Keys.aiGatewayClientID) }
    }

    @Published var aiGatewayClientSecret: String {
        didSet { UserDefaults.standard.set(aiGatewayClientSecret, forKey: Keys.aiGatewayClientSecret) }
    }

    // A plain static shared bearer token — for talking to `ai-router`
    // (a Cloudflare Worker in front of ai-gateway and, later, other
    // backends) instead of ai-gateway directly. When this is set, both
    // Summarize and Downloads send it as `Authorization: Bearer
    // <token>` against `aiGatewayURI` using ai-router's request shape,
    // skipping the OAuth2 exchange entirely — unlike that flow, this
    // token never expires and is never refreshed; it's a fixed
    // credential until manually rotated. Leave blank to keep using the
    // Client ID/Secret OAuth2 flow directly against ai-gateway instead
    // (for both features symmetrically — whichever credential is set
    // decides the backend for everything, not just one feature, so
    // `aiGatewayURI` only ever needs to point at one place at a time).
    @Published var aiGatewayToken: String {
        didSet { UserDefaults.standard.set(aiGatewayToken, forKey: Keys.aiGatewayToken) }
    }

    // Off by default. When off, the Locked screen's "Walk" option (a
    // live gate — playback allowed for as long as you're moving,
    // checked periodically, with nothing banked or saved — see
    // `WalkModeManager`) doesn't show at all. Same reasoning as
    // `enableSimulateRun`: requiring a trip to Settings first is
    // deliberate friction, not a design flaw.
    @Published var enableWalkOption: Bool {
        didSet { UserDefaults.standard.set(enableWalkOption, forKey: Keys.enableWalkOption) }
    }

    // Off by default (audio-only) — while Walk mode is active, this
    // decides whether full video is ever permitted or it's always
    // restricted to Listen Mode. Watching video while actually walking
    // is the thing this defaults against; on lets you opt back into it
    // (e.g. a slow treadmill walk where glancing at the screen is fine).
    @Published var walkAllowsVideo: Bool {
        didSet { UserDefaults.standard.set(walkAllowsVideo, forKey: Keys.walkAllowsVideo) }
    }

    // Each shows/hides its own option on the Locked screen's Exercise
    // picker — same friction-by-design reasoning as `enableWalkOption`.
    // All three camera-tracked exercises (see ExerciseCounter/
    // ExerciseTrainingView) share the one reps/seconds reward economy
    // below rather than each getting its own — "5 reps of any of these
    // = 120 seconds" is meant to feel consistent regardless of which
    // exercise you pick, not a separate dial per exercise.
    @Published var enablePushUpOption: Bool {
        didSet { UserDefaults.standard.set(enablePushUpOption, forKey: Keys.enablePushUpOption) }
    }

    @Published var enableSitUpOption: Bool {
        didSet { UserDefaults.standard.set(enableSitUpOption, forKey: Keys.enableSitUpOption) }
    }

    @Published var enableLungeOption: Bool {
        didSet { UserDefaults.standard.set(enableLungeOption, forKey: Keys.enableLungeOption) }
    }

    // Every this many counted reps (of whichever camera-tracked
    // exercise) banks `secondsPerExerciseSet` of daily allowance (or
    // clears an active cooldown, same mutual-exclusivity rule as a run
    // — see `UsageTracker.completeExerciseReward`), once explicitly
    // claimed rather than granted automatically.
    @Published var repsPerExerciseSet: Int {
        didSet { UserDefaults.standard.set(repsPerExerciseSet, forKey: Keys.repsPerExerciseSet) }
    }

    @Published var secondsPerExerciseSet: Int {
        didSet { UserDefaults.standard.set(secondsPerExerciseSet, forKey: Keys.secondsPerExerciseSet) }
    }

    // Stairs (see StairClimbCounter) is tracked via the phone's
    // barometer (CMPedometer's floor count) rather than the camera, so
    // it gets its own reward pair in a different unit ("floors," not
    // "reps") instead of sharing the one above.
    @Published var enableStairsOption: Bool {
        didSet { UserDefaults.standard.set(enableStairsOption, forKey: Keys.enableStairsOption) }
    }

    @Published var floorsPerStairSet: Int {
        didSet { UserDefaults.standard.set(floorsPerStairSet, forKey: Keys.floorsPerStairSet) }
    }

    @Published var secondsPerStairSet: Int {
        didSet { UserDefaults.standard.set(secondsPerStairSet, forKey: Keys.secondsPerStairSet) }
    }

    // Name of the Shortcut the experimental "Summarize via ChatGPT App"
    // feature invokes (see `ChatGPTShortcutBridge`) — must match exactly
    // what the Shortcut is named in the Shortcuts app.
    @Published var chatGPTShortcutName: String {
        didSet { UserDefaults.standard.set(chatGPTShortcutName, forKey: Keys.chatGPTShortcutName) }
    }

    init() {
        let defaults = UserDefaults.standard

        // `object(forKey:)` returns nil if never set, letting us fall back
        // to our own defaults on first launch (a plain `integer(forKey:)`
        // would silently return 0 instead).
        self.dailyLimitMinutes = defaults.object(forKey: Keys.dailyLimitMinutes) as? Int
            ?? Defaults.dailyLimitMinutes
        self.bingeLimitMinutes = defaults.object(forKey: Keys.bingeLimitMinutes) as? Int
            ?? Defaults.bingeLimitMinutes
        self.cooldownMinutes = defaults.object(forKey: Keys.cooldownMinutes) as? Int
            ?? Defaults.cooldownMinutes
        self.bingeResetAfterMinutes = defaults.object(forKey: Keys.bingeResetAfterMinutes) as? Int
            ?? Defaults.bingeResetAfterMinutes
        self.minutesPerRun = defaults.object(forKey: Keys.minutesPerRun) as? Int
            ?? Defaults.minutesPerRun
        self.qualifyingDistanceKm = defaults.object(forKey: Keys.qualifyingDistanceKm) as? Double
            ?? Defaults.qualifyingDistanceKm
        self.qualifyingDurationMinutes = defaults.object(forKey: Keys.qualifyingDurationMinutes) as? Int
            ?? Defaults.qualifyingDurationMinutes
        self.weightKg = defaults.object(forKey: Keys.weightKg) as? Double
            ?? Defaults.weightKg
        self.carBluetoothDeviceName = defaults.string(forKey: Keys.carBluetoothDeviceName) ?? ""
        self.restrictShorts = defaults.bool(forKey: Keys.restrictShorts)
        self.listenModeEnabled = defaults.bool(forKey: Keys.listenModeEnabled)
        self.enableSimulateRun = defaults.bool(forKey: Keys.enableSimulateRun)
        self.listenRatePercent = defaults.object(forKey: Keys.listenRatePercent) as? Int
            ?? Defaults.listenRatePercent
        self.carRatePercent = defaults.object(forKey: Keys.carRatePercent) as? Int
            ?? Defaults.carRatePercent
        self.aiGatewayURI = defaults.string(forKey: Keys.aiGatewayURI) ?? ""
        self.aiGatewayClientID = defaults.string(forKey: Keys.aiGatewayClientID) ?? ""
        self.aiGatewayClientSecret = defaults.string(forKey: Keys.aiGatewayClientSecret) ?? ""
        self.aiGatewayToken = defaults.string(forKey: Keys.aiGatewayToken) ?? ""
        self.chatGPTShortcutName = defaults.string(forKey: Keys.chatGPTShortcutName) ?? Defaults.chatGPTShortcutName
        self.enableWalkOption = defaults.bool(forKey: Keys.enableWalkOption)
        self.walkAllowsVideo = defaults.bool(forKey: Keys.walkAllowsVideo)
        self.enablePushUpOption = defaults.bool(forKey: Keys.enablePushUpOption)
        self.enableSitUpOption = defaults.bool(forKey: Keys.enableSitUpOption)
        self.enableLungeOption = defaults.bool(forKey: Keys.enableLungeOption)
        self.repsPerExerciseSet = defaults.object(forKey: Keys.repsPerExerciseSet) as? Int
            ?? Defaults.repsPerExerciseSet
        self.secondsPerExerciseSet = defaults.object(forKey: Keys.secondsPerExerciseSet) as? Int
            ?? Defaults.secondsPerExerciseSet
        self.enableStairsOption = defaults.bool(forKey: Keys.enableStairsOption)
        self.floorsPerStairSet = defaults.object(forKey: Keys.floorsPerStairSet) as? Int
            ?? Defaults.floorsPerStairSet
        self.secondsPerStairSet = defaults.object(forKey: Keys.secondsPerStairSet) as? Int
            ?? Defaults.secondsPerStairSet
    }
}
