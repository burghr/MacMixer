// MacMixer v2 — the popover UI: output picker, master slider, per-app sliders.

import SwiftUI
import CoreAudio

struct PopupView: View {
    @EnvironmentObject var model: MixerModel

    private let width: CGFloat = 320

    // User-resizable apps list height, remembered across launches.
    @AppStorage("appsListHeight") private var appsListHeight: Double = 300
    @State private var dragStartHeight: Double? = nil
    @State private var outputHover = false
    private let minListHeight: Double = 140
    private let maxListHeight: Double = 720

    private var currentDevice: AudioDeviceInfo? {
        model.outputDevices.first { $0.id == model.currentOutputID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            if let err = model.startupError {
                errorBanner(err)
            } else if !model.running {
                startingBanner
            } else {
                outputSection

                // Inset divider matching the others; the gap comes from the
                // output section's bottom padding + master's top padding.
                Divider().padding(.horizontal, 12)

                masterSection
                Divider().padding(.horizontal, 12)
                appsSection
                resizeHandle
            }
        }
        .frame(width: width)
        .onAppear { if model.running { model.refreshAll() } }
    }

    // MARK: Header

    private var header: some View {
        HStack {
            Text("MacMixer")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.top, 10)
        .padding(.bottom, 6)
    }

    // MARK: Output picker

    private var outputSection: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("OUTPUT DEVICE")
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)

            Menu {
                ForEach(model.outputDevices) { dev in
                    Button { model.selectOutput(dev.id) } label: {
                        Label(dev.name, systemImage: dev.symbolName)
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: currentDevice?.symbolName ?? "hifispeaker.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                        .frame(width: 20)
                    Text(currentDevice?.name ?? "Output device")
                        .font(.system(size: 12.5, weight: .medium))
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                    Spacer(minLength: 4)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(Color.accentColor)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color.primary.opacity(outputHover ? 0.14 : 0.09))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(outputHover ? 0.22 : 0.12),
                                      lineWidth: 1)
                )
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize(horizontal: false, vertical: true)
            .onHover { hovering in
                outputHover = hovering
                if hovering { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
            .animation(.easeOut(duration: 0.12), value: outputHover)
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 12)
    }

    // MARK: Master

    private var masterSection: some View {
        VolumeRow(
            icon: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            title: "Master",
            iconTint: .primary,
            value: Binding(get: { model.masterVolume }, set: { model.setMaster($0) }),
            range: 0...1,
            trailing: {
                if model.hasMute {
                    Button(action: { model.toggleMute() }) {
                        Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(model.muted ? Color.accentColor : .secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        )
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: Per-app sliders

    private var appsSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Apps")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.top, 6)
                .padding(.bottom, 2)

            ScrollView {
                VStack(spacing: 0) {
                    if model.visibleApps.isEmpty {
                        Text(model.hiddenApps.isEmpty ? "No open apps" : "No visible apps")
                            .font(.system(size: 11))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                    }

                    ForEach(model.visibleApps) { app in
                        appRow(app, hidden: false)
                    }

                    if model.showingHidden && !model.hiddenApps.isEmpty {
                        Divider().padding(.horizontal, 12).padding(.vertical, 4)
                        Text("Hidden")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.bottom, 2)
                        ForEach(model.hiddenApps) { app in
                            appRow(app, hidden: true)
                        }
                    }
                }
            }
            .frame(height: appsListHeight)

            if !model.hiddenApps.isEmpty {
                Button(action: { model.showingHidden.toggle() }) {
                    HStack(spacing: 4) {
                        Image(systemName: model.showingHidden ? "chevron.up" : "chevron.down")
                            .font(.system(size: 9))
                        Text(model.showingHidden
                             ? "Hide hidden apps"
                             : "Show hidden apps (\(model.hiddenApps.count))")
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }
        }
        .padding(.bottom, 8)
    }

    // Drag the bottom edge to resize the apps list; the height is remembered.
    private var resizeHandle: some View {
        ZStack {
            Color.primary.opacity(0.001)          // hit area
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.secondary.opacity(0.4))
                .frame(width: 34, height: 4)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 14)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() }
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    if dragStartHeight == nil { dragStartHeight = appsListHeight }
                    let base = dragStartHeight ?? appsListHeight
                    appsListHeight = min(maxListHeight,
                                         max(minListHeight, base + value.translation.height))
                }
                .onEnded { _ in dragStartHeight = nil }
        )
    }

    @ViewBuilder
    private func appRow(_ app: MixerModel.AppEntry, hidden: Bool) -> some View {
        let boosting = app.volume > MixerModel.normalPercent
        VolumeRow(
            nsIcon: app.icon,
            title: app.name,
            sliderTint: boosting ? .orange : nil,
            value: Binding(
                get: { app.volume },
                set: { newValue in
                    let snapped = abs(newValue - MixerModel.normalPercent) < 4
                        ? MixerModel.normalPercent : newValue
                    model.setVolume(snapped, for: app)
                }
            ),
            range: 0...MixerModel.maxPercent,
            trailing: {
                HStack(spacing: 6) {
                    if boosting {
                        Image(systemName: "bolt.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.orange)
                    }
                    Text("\(Int(app.volume.rounded()))%")
                        .font(.system(size: 10, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(boosting ? Color.orange : Color.secondary)
                    Button(action: { hidden ? model.unhide(app) : model.hide(app) }) {
                        Image(systemName: hidden ? "plus.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundStyle(hidden ? Color.green : Color.secondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .help(hidden ? "Unhide this app" : "Hide this app")
                }
            }
        )
        .opacity(hidden ? 0.6 : 1)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: Banners

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text(message)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
    }

    private var startingBanner: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Starting…")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }
}

/// A labelled volume slider row: icon, title, slider, optional trailing control.
private struct VolumeRow<Trailing: View>: View {
    var icon: String? = nil
    var nsIcon: NSImage? = nil
    let title: String
    var iconTint: Color = .secondary
    var sliderTint: Color? = nil
    @Binding var value: Double
    let range: ClosedRange<Double>
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                iconView
                    .frame(width: 18, height: 18)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Spacer()
                trailing()
            }
            Slider(value: $value, in: range)
                .controlSize(.small)
                .tint(sliderTint)
        }
    }

    @ViewBuilder
    private var iconView: some View {
        if let nsIcon {
            Image(nsImage: nsIcon).resizable().aspectRatio(contentMode: .fit)
        } else if let icon {
            Image(systemName: icon)
                .font(.system(size: 13))
                .foregroundStyle(iconTint)
        }
    }
}
