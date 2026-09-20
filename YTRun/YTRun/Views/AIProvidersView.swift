//
//  AIProvidersView.swift
//  YTRun
//

import SwiftUI

// One Section per possible Summarize backend, each independently
// configured, with one marked Default — that's the only one Summarize
// actually uses; there's no per-request picker in the YouTube screen
// itself. A List/Form (matching every other settings screen in the
// app) rather than literal tabs — simpler to scroll through on a phone
// than paging between tabs for what's really just a handful of fields
// per provider.
struct AIProvidersView: View {
    @EnvironmentObject var settings: AppSettings

    var body: some View {
        Form {
            ForEach(AISummaryProvider.allCases) { provider in
                Section {
                    providerFields(for: provider)
                    defaultRow(for: provider)
                } header: {
                    Text(provider.displayName)
                } footer: {
                    if provider == .ytRunGateway {
                        Text("Reuses the URL and Token from the YTRun Gateway section — nothing extra to configure here.")
                    }
                }
            }
        }
        .navigationTitle("AI Providers")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func providerFields(for provider: AISummaryProvider) -> some View {
        switch provider {
        case .ytRunGateway:
            EmptyView()
        case .openAICompatible:
            TextField("Base URL", text: $settings.openAICompatibleBaseURL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .keyboardType(.URL)
            SecureField("API Key", text: $settings.openAICompatibleAPIKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Model", text: $settings.openAICompatibleModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .gemini:
            SecureField("API Key", text: $settings.geminiAPIKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Model", text: $settings.geminiModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        case .claude:
            SecureField("API Key", text: $settings.claudeAPIKey)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            TextField("Model", text: $settings.claudeModel)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
        }
    }

    @ViewBuilder
    private func defaultRow(for provider: AISummaryProvider) -> some View {
        if settings.defaultSummaryProvider == provider {
            Label("Default for Summarize", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else {
            Button("Set as Default") {
                settings.defaultSummaryProvider = provider
            }
        }
    }
}

#Preview {
    NavigationStack {
        AIProvidersView()
    }
    .environmentObject(AppSettings())
}
