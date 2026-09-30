import SwiftUI

/// Everything about how the gateway runs, for the rare time the owner needs it: address,
/// version, whether it starts at login, where its files are, and the manual controls. Opened
/// from the menu; no other screen shows any of this.
struct GatewayDetailsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: PanelSize.gap) {
                SubscreenHeader(title: "Gateway details") { model.overlay = nil }

                if let error = model.daemon.lastError {
                    Card(tone: .failed) {
                        Text(error)
                            .font(TypeScale.body)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }

                LabeledSection("Gateway", footer: approvalNote) {
                    RowCard {
                        ValueRow("Status") {
                            HStack(spacing: 5) {
                                StatusDot(tone: model.reachable ? .ok : .failed, size: 6)
                                Text(model.reachable ? "Running" : "Not running")
                            }
                        }
                        ValueRow("Address", Wording.address(model.config.baseURL))
                        if let health = model.health {
                            ValueRow("Version", health.version)
                            ValueRow("Running since", health.startedAt.formatted(date: .abbreviated, time: .shortened))
                        }
                        ValueRow("Starts at login", model.daemon.isForegroundRunning ? "No, runs inside this app" : model.daemon.agentState.startsAtLogin)
                    }
                }

                LabeledSection("Controls") {
                    RowCard {
                        control("Restart", detail: nil, button: "Restart", enabled: model.reachable) { model.restartGateway() }
                        if model.daemon.agentState == .requiresApproval {
                            control("Allow at login", detail: "Switch on Telegram Gateway under Allow in the Background.", button: "Open Settings") {
                                model.daemon.openLoginItemsSettings()
                            }
                        }
                        if model.daemon.agentState == .enabled {
                            control("Start at login", detail: "Turning this off stops the gateway.", button: "Turn Off") {
                                model.daemon.unregister()
                                Task { await model.refresh() }
                            }
                        } else {
                            control("Start at login", detail: "Keeps the gateway running after this app quits.", button: "Turn On", enabled: !model.daemon.isForegroundRunning) {
                                model.daemon.register(config: model.config)
                                Task { await model.refresh() }
                            }
                        }
                        if model.daemon.isForegroundRunning {
                            control("Run inside this app", detail: "Stops when the app quits.", button: "Stop") {
                                model.daemon.stopForeground()
                                Task { await model.refresh() }
                            }
                        } else if model.daemon.agentState != .enabled {
                            control("Run inside this app", detail: "Stops when the app quits.", button: "Run", enabled: !model.reachable) {
                                model.daemon.runInForeground(config: model.config)
                                Task { try? await Task.sleep(for: .seconds(1)); await model.refresh() }
                            }
                        }
                        control("Log", detail: nil, button: "Show") { showGatewayLog(model.daemon) }
                    }
                }

                LabeledSection("Telegram key") {
                    RowCard {
                        ValueRow("API ID", model.config.apiId.map { String($0) } ?? "Not set")
                        control("API hash", detail: maskedHash, button: "Change…") {
                            model.overlay = nil
                            model.editingKey = true
                        }
                    }
                }

                LabeledSection("Files") {
                    RowCard {
                        path("Program", model.daemon.daemonURL?.path ?? "Not found")
                        path("Settings", GatewayConfig.fileURL.path)
                        path("Log", model.daemon.logURL.path)
                    }
                }
            }
            .padding(PanelSize.margin)
        }
        .onAppear {
            model.daemon.locate(config: model.config)
            model.daemon.refreshAgentState()
        }
    }

    private var approvalNote: String? {
        model.daemon.agentState == .requiresApproval ? "macOS is waiting for you to allow the gateway to start at login." : nil
    }

    private var maskedHash: String {
        guard let hash = model.config.apiHash, hash.count >= 8 else { return "Not set" }
        return hash.prefix(4) + "…" + hash.suffix(4)
    }

    private func control(_ title: String, detail: String?, button: String, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            TitleAndDetail(title: title, detail: detail)
            Spacer(minLength: 8)
            Button(button, action: action)
                .controlSize(.small)
                .disabled(!enabled)
        }
    }

    private func path(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(TypeScale.body)
                .foregroundStyle(.secondary)
            Text(value)
                .font(TypeScale.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

#Preview("Gateway details") {
    let model = AppModel.preview(.loggedIn)
    model.overlay = .details
    return RootView().environment(model)
}
