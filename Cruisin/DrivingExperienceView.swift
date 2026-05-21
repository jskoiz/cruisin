import MapKit
import SwiftUI

struct DrivingExperienceView: View {
    @ObservedObject var model: DriveGuideModel
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 21.2969, longitude: -157.8498),
            span: MKCoordinateSpan(latitudeDelta: 0.055, longitudeDelta: 0.06)
        )
    )
    @State private var showsAudit = true

    var body: some View {
        ZStack(alignment: .bottom) {
            Map(position: $cameraPosition, interactionModes: [.pan, .zoom, .rotate]) {
                MapPolyline(coordinates: model.route.map(\.coordinate))
                    .stroke(.cyan.opacity(0.72), lineWidth: 5)

                ForEach(model.visibleFacts) { fact in
                    Annotation(fact.name, coordinate: fact.coordinate) {
                        POIPin(
                            category: fact.category,
                            isActive: fact.id == model.lastSpokenFactID
                        )
                    }
                }

                Annotation("Current route position", coordinate: model.currentCoordinate) {
                    CurrentPositionMarker(isRunning: model.isRunning)
                }
            }
            .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .including([.museum, .park, .restaurant, .beach])))
            .ignoresSafeArea()
            .onChange(of: model.currentCoordinate.latitude) { _, _ in updateCamera() }
            .onChange(of: model.currentCoordinate.longitude) { _, _ in updateCamera() }

            VStack(spacing: 10) {
                RouteStatusHeader(model: model)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)

                Spacer()

                NearbyContextPanel(model: model, showsAudit: $showsAudit)
                    .padding(.horizontal, 14)

                ControlStrip(
                    isRunning: model.isRunning,
                    onStart: model.start,
                    onPause: model.pause,
                    onReplay: model.routeReplay,
                    showsAudit: $showsAudit
                )
                .padding(.horizontal, 14)
                .padding(.bottom, 10)
            }
        }
    }

    private func updateCamera() {
        withAnimation(.easeInOut(duration: 0.55)) {
            cameraPosition = .region(
                MKCoordinateRegion(
                    center: model.currentCoordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.028, longitudeDelta: 0.032)
                )
            )
        }
    }
}

private struct RouteStatusHeader: View {
    @ObservedObject var model: DriveGuideModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Honolulu Drive")
                        .font(.headline.weight(.semibold))
                    Text(model.currentLabel)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                VStack(alignment: .trailing, spacing: 6) {
                    Label(model.isRunning ? "Live replay" : "Paused", systemImage: model.isRunning ? "waveform.circle.fill" : "pause.circle")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(model.isRunning ? .green : .orange)
                        .labelStyle(.titleAndIcon)

                    RealtimeStatusBadge(status: String(describing: model.realtimeStatus))
                }
            }

            GuideModePicker(selection: $model.guideVoiceMode)

            ProgressView(value: model.progress)
                .tint(.cyan)

            HStack(spacing: 6) {
                Image(systemName: "speaker.wave.2.fill")
                    .foregroundStyle(.cyan)
                Text(model.narrationStatus)
                    .font(.caption)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 18, y: 10)
    }
}

private struct GuideModePicker: View {
    @Binding var selection: GuideVoiceMode

    var body: some View {
        Picker("Guide voice mode", selection: $selection) {
            Text("Local").tag(GuideVoiceMode.local)
            Text("AI Guide").tag(GuideVoiceMode.aiGuide)
        }
        .pickerStyle(.segmented)
        .font(.caption.weight(.semibold))
        .accessibilityLabel("Guide voice mode")
    }
}

private struct RealtimeStatusBadge: View {
    let status: String

    var body: some View {
        Label("GPT-Realtime-2 \(title)", systemImage: symbol)
            .font(.caption2.weight(.bold))
            .foregroundStyle(color)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(color.opacity(0.14), in: Capsule())
            .accessibilityLabel("GPT-Realtime-2 status \(title)")
    }

    private var normalizedStatus: String {
        let cleaned = status
            .replacingOccurrences(of: "Optional(", with: "")
            .replacingOccurrences(of: ")", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if cleaned.contains("disconnect") || cleaned.isEmpty { return "disconnected" }
        if cleaned.contains("speaking") { return "speaking" }
        if cleaned.contains("fallback") { return "fallback" }
        if cleaned.contains("error") { return "error" }
        if cleaned.contains("connected") { return "connected" }
        return cleaned
    }

    private var title: String {
        switch normalizedStatus {
        case "connected": return "Connected"
        case "speaking": return "Speaking"
        case "fallback": return "Fallback"
        case "error": return "Error"
        case "disconnected": return "Disconnected"
        default: return normalizedStatus.capitalized
        }
    }

    private var symbol: String {
        switch normalizedStatus {
        case "connected": return "checkmark.circle.fill"
        case "speaking": return "waveform.circle.fill"
        case "fallback": return "arrow.triangle.2.circlepath.circle.fill"
        case "error": return "exclamationmark.triangle.fill"
        default: return "xmark.circle.fill"
        }
    }

    private var color: Color {
        switch normalizedStatus {
        case "connected": return .green
        case "speaking": return .cyan
        case "fallback": return .orange
        case "error": return .red
        default: return .secondary
        }
    }
}

private struct NearbyContextPanel: View {
    @ObservedObject var model: DriveGuideModel
    @Binding var showsAudit: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label("Nearby Context", systemImage: "scope")
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text("\(model.nearbyCandidates.count) candidates")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let top = model.nearbyCandidates.first {
                VStack(alignment: .leading, spacing: 4) {
                    Text(top.fact.name)
                        .font(.title3.weight(.semibold))
                        .lineLimit(2)
                    Text(top.fact.narration)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                    Label("\(Int(top.distanceMeters)) m away  \(top.fact.category)", systemImage: "mappin.and.ellipse")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.cyan)
                }
            } else {
                Text("No cached facts are close to the current route position.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            PreferenceCommandRow(model: model)

            if showsAudit {
                AuditPanel(model: model)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 18, y: 10)
    }
}

private struct PreferenceCommandRow: View {
    @ObservedObject var model: DriveGuideModel

    private let demoCommand = "Skip food. Give me the history angle, and keep it short."

    var body: some View {
        Button {
            model.submitUserUtterance(demoCommand)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.orange)
                    .frame(width: 20)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Interrupt / preference")
                        .font(.caption.weight(.semibold))
                    Text(demoCommand)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 6)

                Image(systemName: "paperplane.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.cyan)
            }
            .padding(9)
            .background(Color(.secondarySystemBackground).opacity(0.82), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Send demo preference command")
    }
}

private struct AuditPanel: View {
    @ObservedObject var model: DriveGuideModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()

            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "checklist.checked")
                    .foregroundStyle(.purple)
                Text(model.lastDecisionReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                AuditFieldRow(
                    title: "Model transcript",
                    value: model.lastModelTranscript,
                    emptyText: "No model transcript yet",
                    systemImage: "text.bubble.fill",
                    tint: .cyan
                )
                AuditFieldRow(
                    title: "User utterance",
                    value: model.lastUserUtterance,
                    emptyText: "No user utterance yet",
                    systemImage: "person.wave.2.fill",
                    tint: .blue
                )
                AuditFieldRow(
                    title: "Preference state",
                    value: model.preferenceAuditSummary,
                    emptyText: "Balanced categories",
                    systemImage: "slider.horizontal.3",
                    tint: .green
                )
                AuditFieldRow(
                    title: "Context summary",
                    value: model.lastContextSummary,
                    emptyText: "No context summary yet",
                    systemImage: "doc.text.magnifyingglass",
                    tint: .purple
                )
                AuditFieldRow(
                    title: "Fallback / error",
                    value: model.fallbackErrorState,
                    emptyText: "None reported",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange
                )
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(model.nearbyCandidates.prefix(6)) { candidate in
                        CandidateChip(candidate: candidate)
                    }
                }
            }

            if let event = model.spokenEvents.first {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "quote.bubble.fill")
                        .foregroundStyle(.cyan)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title)
                            .font(.caption.weight(.semibold))
                        Text(event.text)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
            }
        }
    }
}

private struct AuditFieldRow: View {
    let title: String
    let value: String?
    let emptyText: String
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
                Text(displayValue)
                    .font(.caption)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var displayValue: String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? emptyText : trimmed
    }
}

private struct CandidateChip: View {
    let candidate: NearbyCandidate

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(candidate.fact.name)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            Text("\(Int(candidate.distanceMeters)) m \(candidate.fact.category)")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 132, alignment: .leading)
        .padding(8)
        .background(Color(.secondarySystemBackground).opacity(0.82), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct ControlStrip: View {
    let isRunning: Bool
    let onStart: () -> Void
    let onPause: () -> Void
    let onReplay: () -> Void
    @Binding var showsAudit: Bool

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onStart) {
                Label("Start", systemImage: "play.fill")
            }
            .buttonStyle(ControlButtonStyle(tint: .green, isProminent: !isRunning))

            Button(action: onPause) {
                Label("Pause", systemImage: "pause.fill")
            }
            .buttonStyle(ControlButtonStyle(tint: .orange, isProminent: isRunning))

            Button(action: onReplay) {
                Label("Replay", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(ControlButtonStyle(tint: .cyan, isProminent: false))

            Button {
                showsAudit.toggle()
            } label: {
                Image(systemName: showsAudit ? "list.bullet.rectangle.fill" : "list.bullet.rectangle")
                    .accessibilityLabel("Toggle audit panel")
            }
            .buttonStyle(IconButtonStyle())
        }
    }
}

private struct ControlButtonStyle: ButtonStyle {
    let tint: Color
    let isProminent: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .frame(maxWidth: .infinity, minHeight: 46)
            .foregroundStyle(isProminent ? .white : tint)
            .background(isProminent ? tint : Color(.systemBackground).opacity(0.86), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct IconButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.semibold))
            .frame(width: 48, height: 46)
            .foregroundStyle(.purple)
            .background(Color(.systemBackground).opacity(0.86), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .opacity(configuration.isPressed ? 0.72 : 1)
    }
}

private struct CurrentPositionMarker: View {
    let isRunning: Bool

    var body: some View {
        ZStack {
            Circle()
                .fill(.white)
                .frame(width: 42, height: 42)
                .shadow(color: .black.opacity(0.24), radius: 10, y: 4)
            Circle()
                .fill(isRunning ? .green : .orange)
                .frame(width: 30, height: 30)
            Image(systemName: "car.fill")
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
        }
    }
}

private struct POIPin: View {
    let category: String
    let isActive: Bool

    var body: some View {
        Image(systemName: symbol)
            .font(.caption.weight(.bold))
            .frame(width: 28, height: 28)
            .foregroundStyle(.white)
            .background(color, in: Circle())
            .overlay(
                Circle()
                    .stroke(.white, lineWidth: isActive ? 3 : 1.5)
            )
            .shadow(color: .black.opacity(0.22), radius: 8, y: 4)
    }

    private var symbol: String {
        switch category {
        case "food": return "fork.knife"
        case "nature": return "leaf.fill"
        case "area": return "map.fill"
        case "lookout": return "binoculars.fill"
        case "culture": return "theatermasks.fill"
        case "history": return "building.columns.fill"
        default: return "mappin"
        }
    }

    private var color: Color {
        switch category {
        case "food": return .orange
        case "nature": return .green
        case "area": return .blue
        case "lookout": return .teal
        case "culture": return .purple
        case "history": return .brown
        default: return .red
        }
    }
}

struct DrivingExperienceView_Previews: PreviewProvider {
    static var previews: some View {
        DrivingExperienceView(model: DriveGuideModel())
    }
}
