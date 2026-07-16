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

    // When on, the YouTube screen redirects away from any Shorts page
    // (`/shorts/...`) back to the home feed — see `YouTubeWebViewStore`.
    @Published var restrictShorts: Bool {
        didSet { UserDefaults.standard.set(restrictShorts, forKey: Keys.restrictShorts) }
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
    }
}
