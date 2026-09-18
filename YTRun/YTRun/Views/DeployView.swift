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

    @State private var ssid: String?
    @State private var isCheckingWifi = false
    @State private var isShowingConfirmation = false
    @State private var isDeploying = false
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
                HStack {
                    Text("Mac mini Wi-Fi")
                    Spacer()
                    if isCheckingWifi {
                        ProgressView()
                    } else {
                        Text(ssid ?? "Unknown")
                            .foregroundStyle(.secondary)
                    }
                }
                Button("Refresh") {
                    Task { await checkWifi() }
                }
                .disabled(isCheckingWifi || isDeploying)
            } header: {
                Text("Network")
            } footer: {
                Text("For the update to actually reach this phone, it needs to be on the same Wi-Fi network as your Mac mini — this only checks and shows the name, it doesn't switch anything for you.")
            }

            Section {
                if isDeploying {
                    HStack {
                        ProgressView()
                        Text("Updating…")
                    }
                } else {
                    Button("Update App") {
                        isShowingConfirmation = true
                    }
                    .disabled(isCheckingWifi)
                }
            } footer: {
                Text("Pulls the latest code, rebuilds, and reinstalls onto this phone — takes a few minutes. The app will quit partway through when the new build replaces it; just reopen it afterward.")
            }
        }
        .navigationTitle("Update App")
        .onAppear {
            Task {
                await checkWifi()
                await resumeIfAlreadyRunning()
            }
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

    private func checkWifi() async {
        isCheckingWifi = true
        defer { isCheckingWifi = false }
        switch await aiGatewayClient.macWifiSSID(settings: settings) {
        case .success(let name):
            ssid = name ?? "Not connected"
        case .failure(let error):
            ssid = nil
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
            await pollUntilFinished()
        }
    }

    private func runDeploy() async {
        isDeploying = true
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
                switch info.status {
                case .success:
                    resultMessage = "Update installed — reopen the app to use the new version."
                    return
                case .failed:
                    resultMessage = "Update failed: \(info.logTail ?? "unknown error")"
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
