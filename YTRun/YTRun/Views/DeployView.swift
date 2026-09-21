//
//  DeployView.swift
//  YTRun
//

import SwiftUI

// Lets this personal, free-account install update itself — pulls the
// latest code, rebuilds, and reinstalls onto this phone via the Mac
// mini, without needing a cable or Xcode open on it. See
// AIGatewayClient's mac_deploy methods for why this polls rather than
// waiting on one long call, and install_to_device.sh (in this repo)
// for what actually runs server-side.
struct DeployView: View {
    @EnvironmentObject var settings: AppSettings
    @EnvironmentObject var aiGatewayClient: AIGatewayClient

    @State private var isChecking = false
    @State private var isShowingConfirmation = false
    @State private var isDeploying = false
    @State private var liveLog = ""
    @State private var resultMessage: String?

    // A deploy is a multi-minute clean build — 20 minutes is generous
    // headroom over the 900s the server itself gives up at, just so a
    // genuinely stuck poll loop doesn't run forever if something on
    // the server side went wrong in a way that never updates status.
    private static let maxWaitSeconds: TimeInterval = 20 * 60
    private static let pollIntervalNanoseconds: UInt64 = 3_000_000_000

    var body: some View {
        Form {
            Section {
                if let installDate = BuildInfo.installDate {
                    HStack {
                        Text("Last installed")
                        Spacer()
                        Text(installDate.formatted(date: .abbreviated, time: .shortened))
                            .foregroundStyle(.secondary)
                    }
                }
                if let hash = BuildInfo.commitHash {
                    HStack {
                        Text("Commit")
                        Spacer()
                        Text(BuildInfo.commitDate.map { "\(hash) · \($0.formatted(date: .abbreviated, time: .omitted))" } ?? hash)
                            .foregroundStyle(.secondary)
                    }
                }
                if let expirationDate = ProvisioningProfile.expirationDate,
                   let daysRemaining = ProvisioningProfile.daysRemaining() {
                    let isUrgent = daysRemaining <= 2
                    HStack {
                        Text("Expires")
                        Spacer()
                        Text("\(daysRemaining <= 0 ? "today" : "\(daysRemaining)d") · \(expirationDate.formatted(date: .abbreviated, time: .omitted))")
                            .foregroundStyle(isUrgent ? .red : .secondary)
                            .fontWeight(isUrgent ? .semibold : .regular)
                    }
                }
                if isChecking {
                    HStack {
                        ProgressView()
                        Text("Checking…")
                    }
                } else if isDeploying {
                    HStack {
                        ProgressView()
                        Text("Updating…")
                    }
                } else {
                    Button("Update App") {
                        Task { await beginUpdateFlow() }
                    }
                }
                // Stays visible after finishing too (until the next tap
                // clears it) — a failure's alert just says "see the log
                // above," so it needs to still be there.
                if !liveLog.isEmpty {
                    ScrollView {
                        Text(liveLog)
                            .font(.system(size: 11, design: .monospaced))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(height: 220)
                }
            } footer: {
                Text("Pulls the latest code, rebuilds, and reinstalls onto this phone — takes a few minutes. The app will quit partway through when the new build replaces it; just reopen it afterward.")
            }
        }
        .navigationTitle("Update App")
        .onAppear {
            Task { await resumeIfAlreadyRunning() }
        }
        .confirmationDialog(
            "Update the app now?",
            isPresented: $isShowingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Update", role: .destructive) {
                Task { await runDeploy() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This rebuilds and reinstalls the app — it will quit unexpectedly partway through. Reopen it afterward to use the new version.")
        }
        .alert("Update App", isPresented: Binding(
            get: { resultMessage != nil },
            set: { if !$0 { resultMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(resultMessage ?? "")
        }
    }

    // Checks readiness right when the button is tapped, rather than
    // showing a persistent status row up front — the Mac's own
    // pairing/reachability is what decides whether this can proceed at
    // all (see mac_deploy's "proceed_ok"), so there's nothing useful to
    // show until the moment it actually matters.
    private func beginUpdateFlow() async {
        isChecking = true
        let readiness = await aiGatewayClient.macWifiStatus(settings: settings)
        isChecking = false
        switch readiness {
        case .success(let info):
            if info.proceedOK {
                isShowingConfirmation = true
            } else {
                resultMessage = "Not paired — move to the same Wi-Fi as your Mac mini and try again."
            }
        case .failure(let error):
            resultMessage = error.message
        }
    }

    // Reopening this screen while a deploy kicked off earlier is still
    // running (e.g. the user navigated away and back) should reflect
    // that instead of showing a blank "Update App" button as if nothing
    // were happening.
    private func resumeIfAlreadyRunning() async {
        guard !isDeploying else { return }
        if case .success(let info) = await aiGatewayClient.deployStatus(settings: settings), info.status == .running {
            isDeploying = true
            liveLog = info.logTail ?? ""
            await pollUntilFinished()
        }
    }

    private func runDeploy() async {
        isDeploying = true
        liveLog = ""
        switch await aiGatewayClient.startDeploy(settings: settings) {
        case .failure(let error):
            // A 409 here just means one's already running (e.g. started
            // from a previous tap, or another device) — that's not a
            // failure worth surfacing, just keep polling it instead.
            guard error.message.contains("already in progress") else {
                isDeploying = false
                resultMessage = error.message
                return
            }
        case .success:
            break
        }
        await pollUntilFinished()
    }

    private func pollUntilFinished() async {
        defer { isDeploying = false }
        let deadline = Date().addingTimeInterval(Self.maxWaitSeconds)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: Self.pollIntervalNanoseconds)
            switch await aiGatewayClient.deployStatus(settings: settings) {
            case .success(let info):
                if let logTail = info.logTail {
                    liveLog = logTail
                }
                switch info.status {
                case .success:
                    resultMessage = "Update installed — reopen the app to use the new version."
                    return
                case .failed:
                    resultMessage = "Update failed — see the log above for details."
                    return
                case .idle, .running:
                    continue
                }
            case .failure(let error):
                resultMessage = error.message
                return
            }
        }
        resultMessage = "Still running after \(Int(Self.maxWaitSeconds / 60)) minutes — check on it from the Mac directly."
    }
}

#Preview {
    NavigationStack {
        DeployView()
    }
    .environmentObject(AppSettings())
    .environmentObject(AIGatewayClient())
}
