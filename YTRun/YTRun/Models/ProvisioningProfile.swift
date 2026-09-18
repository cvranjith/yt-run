//
//  ProvisioningProfile.swift
//  YTRun
//

import Foundation

// A personal (free Apple Developer account) install expires — 7 days
// typically, since that's what a free-account provisioning profile is
// valid for — silently turning into an app that just won't launch
// until reinstalled from Xcode. This reads that actual expiration date
// straight out of the app's own embedded provisioning profile, so
// ContentView can show a reminder before that happens instead of it
// being a surprise.
enum ProvisioningProfile {
    // Computed once per launch (a `static let`, not a function) since
    // it means real file I/O + parsing — cheap either way, but no
    // reason to repeat it every time the home screen redraws.
    static let expirationDate: Date? = readExpirationDate()

    // `embedded.mobileprovision` is a CMS/PKCS#7-signed blob, not a
    // plain plist — Xcode embeds it verbatim in every non-App-Store
    // build (a TestFlight/App Store build has no such file at all, so
    // this correctly returns nil there rather than crashing or
    // guessing). The actual plist we want is a plain-text XML chunk
    // sitting inside that binary blob; reading the whole file as
    // Latin-1 (which can decode *any* byte sequence, unlike UTF-8) lets
    // us find the `<?xml ... </plist>` markers by simple string
    // search without needing a real CMS/ASN.1 parser just for this.
    private static func readExpirationDate() -> Date? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let data = try? Data(contentsOf: url),
              let content = String(data: data, encoding: .isoLatin1) else {
            return nil
        }
        guard let start = content.range(of: "<?xml"),
              let end = content.range(of: "</plist>") else {
            return nil
        }
        let plistString = content[start.lowerBound..<end.upperBound]
        guard let plistData = String(plistString).data(using: .isoLatin1),
              let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return plist["ExpirationDate"] as? Date
    }

    static func daysRemaining(from now: Date = Date()) -> Int? {
        guard let expirationDate else { return nil }
        let seconds = expirationDate.timeIntervalSince(now)
        // Rounds up (a Calendar day-component diff would round 23h59m
        // down to "0 days left", understating urgency by almost a full
        // day right when it matters most).
        return Int((seconds / 86400).rounded(.up))
    }
}
