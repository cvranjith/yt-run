//
//  BuildInfo.swift
//  YTRun
//

import Foundation

// Which commit this running build came from, and when it was actually
// installed — shown on the Update App screen so it's obvious whether
// an update actually landed.
//
// Deliberately NOT read from any filesystem timestamp (an app bundle's
// own creation/modification date, or even its container directory's)
// — confirmed by hand that both report 1 Jan 1970 on a real device
// install here, since the archive/install tooling on one end or the
// other doesn't preserve real dates the way you'd hope. Instead,
// install_to_device.sh stamps these three values straight into
// Info.plist as plain strings right before each build, so they ride
// along as actual bundle *content* — immune to whatever packaging or
// install metadata is or isn't preserved.
enum BuildInfo {
    static var commitHash: String? {
        Bundle.main.infoDictionary?["YTBuildCommitHash"] as? String
    }

    static var commitDate: Date? {
        date(fromInfoKey: "YTBuildCommitDate")
    }

    static var installDate: Date? {
        date(fromInfoKey: "YTBuildInstallDate")
    }

    private static func date(fromInfoKey key: String) -> Date? {
        guard let string = Bundle.main.infoDictionary?[key] as? String else { return nil }
        return ISO8601DateFormatter().date(from: string)
    }
}
