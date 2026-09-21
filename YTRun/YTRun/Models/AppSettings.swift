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
        static let secondsCreditPerRunMinute = "secondsCreditPerRunMinute"
        static let weightKg = "weightKg"
        static let restrictShorts = "restrictShorts"
        static let listenModeEnabled = "listenModeEnabled"
        static let aiGatewayURI = "aiGatewayURI"
        static let aiGatewayToken = "aiGatewayToken"
        static let chatGPTShortcutName = "chatGPTShortcutName"
        static let enableWalkOption = "enableWalkOption"
        static let walkAllowsVideo = "walkAllowsVideo"
        static let enablePushUpOption = "enablePushUpOption"
        static let enableSitUpOption = "enableSitUpOption"
        static let enableLungeOption = "enableLungeOption"
        static let repsPerPushUpSet = "repsPerPushUpSet"
        static let secondsPerPushUpSet = "secondsPerPushUpSet"
        static let repsPerSitUpSet = "repsPerSitUpSet"
        static let secondsPerSitUpSet = "secondsPerSitUpSet"
        static let repsPerLungeSet = "repsPerLungeSet"
        static let secondsPerLungeSet = "secondsPerLungeSet"
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
        static let ledgerWindowDays = "ledgerWindowDays"
        static let stepsPerCreditSet = "stepsPerCreditSet"
        static let secondsPerStepCredit = "secondsPerStepCredit"
        static let secondsPerCreditUse = "secondsPerCreditUse"
        static let ledgerStartDate = "ledgerStartDate"
    }

    private enum Defaults {
        static let dailyLimitMinutes = 60
        static let bingeLimitMinutes = 20
        // Defaults to double the binge limit, per the original ask — but
        // stored as its own independent setting rather than always being
        // recomputed, so changing one later doesn't silently change the
        // other.
        static let cooldownMinutes = 40
        static let secondsCreditPerRunMinute = 60
        static let weightKg = 70.0
        static let chatGPTShortcutName = "YTRun Summarize"
        static let repsPerSet = 5
        static let secondsPerSet = 120
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

    // A run's reward is straight proportional currency — no distance/
    // duration qualifying threshold: every minute actually run is worth
    // this many seconds (default 60, i.e. 1:1 — "run 30 min, that's 30
    // min of currency"). See `RunView.finishRun()`, and `UsageTracker
    // .isLockedOut` for whether a given run's reward extends today's
    // real allowance or just banks Energy Ledger currency.
    @Published var secondsCreditPerRunMinute: Int {
        didSet { UserDefaults.standard.set(secondsCreditPerRunMinute, forKey: Keys.secondsCreditPerRunMinute) }
    }

    // Used only for a rough calorie estimate on saved runs (no HealthKit,
    // no heart rate — just distance × weight, so treat it as approximate).
    @Published var weightKg: Double {
        didSet { UserDefaults.standard.set(weightKg, forKey: Keys.weightKg) }
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
    // `WalkModeManager`) doesn't show at all. Requiring a trip to the
    // Exercises screen first is deliberate friction, not a design flaw.
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
    // picker. Unlike the shared economy this app started with, each of
    // the three camera-tracked exercises now has its own independent
    // reps/reward pair below — a push-up and a lunge don't cost the same
    // effort, so there's no reason they should earn the same either.
    @Published var enablePushUpOption: Bool {
        didSet { UserDefaults.standard.set(enablePushUpOption, forKey: Keys.enablePushUpOption) }
    }

    @Published var enableSitUpOption: Bool {
        didSet { UserDefaults.standard.set(enableSitUpOption, forKey: Keys.enableSitUpOption) }
    }

    @Published var enableLungeOption: Bool {
        didSet { UserDefaults.standard.set(enableLungeOption, forKey: Keys.enableLungeOption) }
    }

    // Every this many counted push-ups banks `secondsPerPushUpSet` —
    // extends today's real allowance if claimed while locked out, or
    // just banks Energy Ledger currency otherwise (see `UsageTracker
    // .isLockedOut`, `ExerciseTrainingView.claimReward()`).
    @Published var repsPerPushUpSet: Int {
        didSet { UserDefaults.standard.set(repsPerPushUpSet, forKey: Keys.repsPerPushUpSet) }
    }

    @Published var secondsPerPushUpSet: Int {
        didSet { UserDefaults.standard.set(secondsPerPushUpSet, forKey: Keys.secondsPerPushUpSet) }
    }

    @Published var repsPerSitUpSet: Int {
        didSet { UserDefaults.standard.set(repsPerSitUpSet, forKey: Keys.repsPerSitUpSet) }
    }

    @Published var secondsPerSitUpSet: Int {
        didSet { UserDefaults.standard.set(secondsPerSitUpSet, forKey: Keys.secondsPerSitUpSet) }
    }

    @Published var repsPerLungeSet: Int {
        didSet { UserDefaults.standard.set(repsPerLungeSet, forKey: Keys.repsPerLungeSet) }
    }

    @Published var secondsPerLungeSet: Int {
        didSet { UserDefaults.standard.set(secondsPerLungeSet, forKey: Keys.secondsPerLungeSet) }
    }

    // Stairs (see StairClimbCounter) is tracked via the phone's
    // barometer (CMPedometer's floor count) rather than the camera, so
    // it gets its own reward pair in a different unit ("floors," not
    // "reps") instead of sharing the ones above.
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

    // A rolling honesty ledger (see `EnergyLedgerManager`) tracking
    // earned credit (steps, read passively via CMPedometer, plus
    // whatever's explicitly claimed via push-ups/sit-ups/lunges/stairs/
    // runs while *not* locked out) against actual watch time, over
    // `ledgerWindowDays`. Always on — it never blocks anything by
    // itself, it only powers the Home/Locked-screen balance readout and
    // the "Use Credit" button, which can push it negative with no
    // ceiling (a deliberate "pay later" honesty account, not a second
    // hard limit).
    //
    // How many trailing days feed the rolling balance — old surplus/debt
    // ages out after this many days rather than accumulating forever.
    // Note: CMPedometer typically only retains ~7 days of step history on
    // device, so a window much longer than that will just read 0 step
    // credit for the older days in it.
    @Published var ledgerWindowDays: Int {
        didSet { UserDefaults.standard.set(ledgerWindowDays, forKey: Keys.ledgerWindowDays) }
    }

    // "10,000 steps = 60 minutes" as two numbers rather than one derived
    // rate, so the Exercises screen can show it exactly the way it's
    // usually thought about. Applied proportionally (not floored to
    // whole sets the way reps are) since steps accrue continuously in
    // the background rather than through a discrete claim action.
    @Published var stepsPerCreditSet: Int {
        didSet { UserDefaults.standard.set(stepsPerCreditSet, forKey: Keys.stepsPerCreditSet) }
    }

    @Published var secondsPerStepCredit: Int {
        didSet { UserDefaults.standard.set(secondsPerStepCredit, forKey: Keys.secondsPerStepCredit) }
    }

    // How much extra time one tap of "Use Credit" on the Locked screen
    // grants — a fixed chunk, not "unlock everything at once." Debits the
    // ledger by the same amount with no floor, since paying it back later
    // is left entirely up to you.
    @Published var secondsPerCreditUse: Int {
        didSet { UserDefaults.standard.set(secondsPerCreditUse, forKey: Keys.secondsPerCreditUse) }
    }

    // Set by "Reset Balance" (Settings' Energy Ledger section) — the
    // rolling window never looks earlier than this, so old debt/surplus
    // stops counting without touching any actual `WatchSegment`/
    // `LedgerEvent` row. `nil` (the default) means no cutoff at all.
    @Published var ledgerStartDate: Date? {
        didSet {
            if let ledgerStartDate {
                UserDefaults.standard.set(ledgerStartDate, forKey: Keys.ledgerStartDate)
            } else {
                UserDefaults.standard.removeObject(forKey: Keys.ledgerStartDate)
            }
        }
    }

    // Name of the Shortcut the experimental "Summarize via ChatGPT App"
    // feature invokes (see `ChatGPTShortcutBridge`) — must match exactly
    // what the Shortcut is named in the Shortcuts app. Configured on the
    // "AI Providers" screen alongside the other summarization backends.
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
        self.secondsCreditPerRunMinute = defaults.object(forKey: Keys.secondsCreditPerRunMinute) as? Int
            ?? Defaults.secondsCreditPerRunMinute
        self.weightKg = defaults.object(forKey: Keys.weightKg) as? Double
            ?? Defaults.weightKg
        self.restrictShorts = defaults.bool(forKey: Keys.restrictShorts)
        self.listenModeEnabled = defaults.bool(forKey: Keys.listenModeEnabled)
        self.aiGatewayURI = defaults.string(forKey: Keys.aiGatewayURI) ?? Defaults.aiGatewayURI
        self.aiGatewayToken = defaults.string(forKey: Keys.aiGatewayToken) ?? ""
        self.chatGPTShortcutName = defaults.string(forKey: Keys.chatGPTShortcutName) ?? Defaults.chatGPTShortcutName
        self.enableWalkOption = defaults.bool(forKey: Keys.enableWalkOption)
        self.walkAllowsVideo = defaults.bool(forKey: Keys.walkAllowsVideo)
        self.enablePushUpOption = defaults.bool(forKey: Keys.enablePushUpOption)
        self.enableSitUpOption = defaults.bool(forKey: Keys.enableSitUpOption)
        self.enableLungeOption = defaults.bool(forKey: Keys.enableLungeOption)
        self.repsPerPushUpSet = defaults.object(forKey: Keys.repsPerPushUpSet) as? Int
            ?? Defaults.repsPerSet
        self.secondsPerPushUpSet = defaults.object(forKey: Keys.secondsPerPushUpSet) as? Int
            ?? Defaults.secondsPerSet
        self.repsPerSitUpSet = defaults.object(forKey: Keys.repsPerSitUpSet) as? Int
            ?? Defaults.repsPerSet
        self.secondsPerSitUpSet = defaults.object(forKey: Keys.secondsPerSitUpSet) as? Int
            ?? Defaults.secondsPerSet
        self.repsPerLungeSet = defaults.object(forKey: Keys.repsPerLungeSet) as? Int
            ?? Defaults.repsPerSet
        self.secondsPerLungeSet = defaults.object(forKey: Keys.secondsPerLungeSet) as? Int
            ?? Defaults.secondsPerSet
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
        self.ledgerWindowDays = defaults.object(forKey: Keys.ledgerWindowDays) as? Int
            ?? Defaults.ledgerWindowDays
        self.stepsPerCreditSet = defaults.object(forKey: Keys.stepsPerCreditSet) as? Int
            ?? Defaults.stepsPerCreditSet
        self.secondsPerStepCredit = defaults.object(forKey: Keys.secondsPerStepCredit) as? Int
            ?? Defaults.secondsPerStepCredit
        self.secondsPerCreditUse = defaults.object(forKey: Keys.secondsPerCreditUse) as? Int
            ?? Defaults.secondsPerCreditUse
        self.ledgerStartDate = defaults.object(forKey: Keys.ledgerStartDate) as? Date
    }
}
