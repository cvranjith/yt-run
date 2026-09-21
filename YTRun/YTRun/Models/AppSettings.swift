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
        static let defaultSummaryProvider = "defaultSummaryProvider"
        static let openAICompatibleBaseURL = "openAICompatibleBaseURL"
        static let openAICompatibleAPIKey = "openAICompatibleAPIKey"
        static let openAICompatibleModel = "openAICompatibleModel"
        static let geminiAPIKey = "geminiAPIKey"
        static let geminiModel = "geminiModel"
        static let claudeAPIKey = "claudeAPIKey"
        static let claudeModel = "claudeModel"
        static let enableEnergyLedger = "enableEnergyLedger"
        static let ledgerWindowDays = "ledgerWindowDays"
        static let stepsPerCreditSet = "stepsPerCreditSet"
        static let secondsPerStepCredit = "secondsPerStepCredit"
        static let secondsPerCreditUse = "secondsPerCreditUse"
        static let enableLateNightPenalty = "enableLateNightPenalty"
        static let lateNightStartHour = "lateNightStartHour"
        static let lateNightEndHour = "lateNightEndHour"
        static let lateNightPenaltySecondsPerMinute = "lateNightPenaltySecondsPerMinute"
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
        // A live, shared personal deployment — bundled so other users
        // don't have to be told a URL by hand; they still each need
        // their own Token, which is the actual per-person gate. See
        // AIGatewayClient's own header comment for the full picture.
        static let aiGatewayURI = "https://ai-router.cvranjith.workers.dev"
        static let openAICompatibleBaseURL = "https://api.openai.com/v1"
        static let openAICompatibleModel = "gpt-4o-mini"
        static let geminiModel = "gemini-2.0-flash"
        static let claudeModel = "claude-haiku-4-5-20251001"
        static let ledgerWindowDays = 7
        static let stepsPerCreditSet = 10000
        static let secondsPerStepCredit = 3600
        static let secondsPerCreditUse = 900
        static let lateNightStartHour = 22
        static let lateNightEndHour = 5
        static let lateNightPenaltySecondsPerMinute = 60
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

    // Base URL of ai-router — e.g.
    // "https://ai-router.<subdomain>.workers.dev" — branded "YTRun
    // Gateway" in Settings/UI since it also powers Downloads, not just
    // AI features. Stored the same way as every other setting here
    // (plain UserDefaults, not Keychain) — consistent with the
    // gateway's own server-side config, which is equally plaintext-on-
    // disk for this personal, single-user setup.
    @Published var aiGatewayURI: String {
        didSet { UserDefaults.standard.set(aiGatewayURI, forKey: Keys.aiGatewayURI) }
    }

    // A plain static shared bearer token — sent as `Authorization:
    // Bearer <token>` against `aiGatewayURI` for both Summarize and
    // Downloads. Never expires, never refreshed; a fixed credential
    // until manually rotated. (An earlier version also supported an
    // OAuth2 Client ID/Secret flow to a self-hosted ai-gateway
    // directly, bypassing ai-router — removed once that path stopped
    // being used, rather than carried along unused.)
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

    // Which backend "Summarize" actually uses — YTRun Gateway (the
    // default; reuses `aiGatewayURI`/`aiGatewayToken` above) or a
    // direct call to a provider using the app's own client-side
    // transcript fetch (see AIGatewayClient's direct-provider
    // adapters), each configured on the "AI Providers" screen. Picking
    // one here is silent/global — Summarize itself has no per-request
    // provider picker, just whichever this is set to.
    @Published var defaultSummaryProvider: AISummaryProvider {
        didSet { UserDefaults.standard.set(defaultSummaryProvider.rawValue, forKey: Keys.defaultSummaryProvider) }
    }

    // OpenAI-compatible chat-completions endpoint — also covers Grok
    // (genuinely OpenAI-SDK-compatible) and any self-hosted compatible
    // server, just by pointing the base URL elsewhere with that
    // provider's own key/model.
    @Published var openAICompatibleBaseURL: String {
        didSet { UserDefaults.standard.set(openAICompatibleBaseURL, forKey: Keys.openAICompatibleBaseURL) }
    }

    @Published var openAICompatibleAPIKey: String {
        didSet { UserDefaults.standard.set(openAICompatibleAPIKey, forKey: Keys.openAICompatibleAPIKey) }
    }

    @Published var openAICompatibleModel: String {
        didSet { UserDefaults.standard.set(openAICompatibleModel, forKey: Keys.openAICompatibleModel) }
    }

    @Published var geminiAPIKey: String {
        didSet { UserDefaults.standard.set(geminiAPIKey, forKey: Keys.geminiAPIKey) }
    }

    @Published var geminiModel: String {
        didSet { UserDefaults.standard.set(geminiModel, forKey: Keys.geminiModel) }
    }

    @Published var claudeAPIKey: String {
        didSet { UserDefaults.standard.set(claudeAPIKey, forKey: Keys.claudeAPIKey) }
    }

    @Published var claudeModel: String {
        didSet { UserDefaults.standard.set(claudeModel, forKey: Keys.claudeModel) }
    }

    // Off by default. A separate, parallel mechanic on top of the hard
    // daily/binge gates above — not a replacement for them. While on, a
    // rolling honesty ledger (see `EnergyLedgerManager`) tracks earned
    // credit (steps, read passively via CMPedometer, plus whatever's
    // explicitly claimed via push-ups/sit-ups/lunges/stairs/runs) against
    // actual watch time, over `ledgerWindowDays`. It never blocks
    // anything by itself — it only powers the LockedView balance readout
    // and the "Use Credit" button, which can push the ledger negative
    // with no ceiling (a deliberate "pay later" honesty account, not a
    // second hard limit).
    @Published var enableEnergyLedger: Bool {
        didSet { UserDefaults.standard.set(enableEnergyLedger, forKey: Keys.enableEnergyLedger) }
    }

    // How many trailing days feed the rolling balance — old surplus/debt
    // ages out after this many days rather than accumulating forever.
    // Note: CMPedometer typically only retains ~7 days of step history on
    // device, so a window much longer than that will just read 0 step
    // credit for the older days in it.
    @Published var ledgerWindowDays: Int {
        didSet { UserDefaults.standard.set(ledgerWindowDays, forKey: Keys.ledgerWindowDays) }
    }

    // "10,000 steps = 60 minutes" as two numbers rather than one derived
    // rate, so the Settings UI can show it exactly the way it's usually
    // thought about. Applied proportionally (not floored to whole sets
    // the way reps are) since steps accrue continuously in the
    // background rather than through a discrete claim action.
    @Published var stepsPerCreditSet: Int {
        didSet { UserDefaults.standard.set(stepsPerCreditSet, forKey: Keys.stepsPerCreditSet) }
    }

    @Published var secondsPerStepCredit: Int {
        didSet { UserDefaults.standard.set(secondsPerStepCredit, forKey: Keys.secondsPerStepCredit) }
    }

    // How much extra time one tap of "Use Credit" on the Locked screen
    // grants — a fixed chunk, not "unlock everything at once." Debits the
    // ledger by the same amount with no floor, since paying it back later
    // is left entirely up to you (see `enableEnergyLedger`).
    @Published var secondsPerCreditUse: Int {
        didSet { UserDefaults.standard.set(secondsPerCreditUse, forKey: Keys.secondsPerCreditUse) }
    }

    // Off by default. An extra deduction from the Energy Ledger (see
    // `EnergyLedgerManager`) for any watching that falls inside the
    // configured hours — on top of that time already counting as normal
    // spend, not instead of it, so it's a real disincentive rather than
    // just a relabeling. Derived live from `WatchSegment` timestamps each
    // refresh, the same way step credit is derived live from CMPedometer
    // — nothing about it is separately logged or stored.
    @Published var enableLateNightPenalty: Bool {
        didSet { UserDefaults.standard.set(enableLateNightPenalty, forKey: Keys.enableLateNightPenalty) }
    }

    // 24-hour clock; `lateNightStartHour > lateNightEndHour` (the default,
    // 22 and 5) means the window wraps past midnight.
    @Published var lateNightStartHour: Int {
        didSet { UserDefaults.standard.set(lateNightStartHour, forKey: Keys.lateNightStartHour) }
    }

    @Published var lateNightEndHour: Int {
        didSet { UserDefaults.standard.set(lateNightEndHour, forKey: Keys.lateNightEndHour) }
    }

    @Published var lateNightPenaltySecondsPerMinute: Int {
        didSet { UserDefaults.standard.set(lateNightPenaltySecondsPerMinute, forKey: Keys.lateNightPenaltySecondsPerMinute) }
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
        self.aiGatewayURI = defaults.string(forKey: Keys.aiGatewayURI) ?? Defaults.aiGatewayURI
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
        self.defaultSummaryProvider = (defaults.string(forKey: Keys.defaultSummaryProvider)).flatMap(AISummaryProvider.init(rawValue:))
            ?? .ytRunGateway
        self.openAICompatibleBaseURL = defaults.string(forKey: Keys.openAICompatibleBaseURL) ?? Defaults.openAICompatibleBaseURL
        self.openAICompatibleAPIKey = defaults.string(forKey: Keys.openAICompatibleAPIKey) ?? ""
        self.openAICompatibleModel = defaults.string(forKey: Keys.openAICompatibleModel) ?? Defaults.openAICompatibleModel
        self.geminiAPIKey = defaults.string(forKey: Keys.geminiAPIKey) ?? ""
        self.geminiModel = defaults.string(forKey: Keys.geminiModel) ?? Defaults.geminiModel
        self.claudeAPIKey = defaults.string(forKey: Keys.claudeAPIKey) ?? ""
        self.claudeModel = defaults.string(forKey: Keys.claudeModel) ?? Defaults.claudeModel
        self.enableEnergyLedger = defaults.bool(forKey: Keys.enableEnergyLedger)
        self.ledgerWindowDays = defaults.object(forKey: Keys.ledgerWindowDays) as? Int
            ?? Defaults.ledgerWindowDays
        self.stepsPerCreditSet = defaults.object(forKey: Keys.stepsPerCreditSet) as? Int
            ?? Defaults.stepsPerCreditSet
        self.secondsPerStepCredit = defaults.object(forKey: Keys.secondsPerStepCredit) as? Int
            ?? Defaults.secondsPerStepCredit
        self.secondsPerCreditUse = defaults.object(forKey: Keys.secondsPerCreditUse) as? Int
            ?? Defaults.secondsPerCreditUse
        self.enableLateNightPenalty = defaults.bool(forKey: Keys.enableLateNightPenalty)
        self.lateNightStartHour = defaults.object(forKey: Keys.lateNightStartHour) as? Int
            ?? Defaults.lateNightStartHour
        self.lateNightEndHour = defaults.object(forKey: Keys.lateNightEndHour) as? Int
            ?? Defaults.lateNightEndHour
        self.lateNightPenaltySecondsPerMinute = defaults.object(forKey: Keys.lateNightPenaltySecondsPerMinute) as? Int
            ?? Defaults.lateNightPenaltySecondsPerMinute
    }
}
