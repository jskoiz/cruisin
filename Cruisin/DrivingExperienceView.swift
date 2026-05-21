import MapKit
import SwiftUI

struct DrivingExperienceView: View {
    @ObservedObject var model: DriveGuideModel
    @State private var cameraPosition: MapCameraPosition = .region(
        MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: 21.2785, longitude: -157.8277),
            span: MapZoomLevel.street.span
        )
    )
    @State private var mapZoomLevel: MapZoomLevel = .street
    @State private var followsRoutePosition = true
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
            .onChange(of: cameraPosition.positionedByUser) { _, positionedByUser in
                if positionedByUser {
                    followsRoutePosition = false
                }
            }
            .onAppear {
                updateCamera(animated: false)
            }

            VStack(spacing: 10) {
                RouteStatusHeader(model: model)
                    .padding(.horizontal, 14)
                    .padding(.top, 10)

                MapCameraControls(
                    selection: Binding(
                        get: { mapZoomLevel },
                        set: { zoomLevel in
                            mapZoomLevel = zoomLevel
                            recenterOnRoute()
                        }
                    ),
                    followsRoutePosition: followsRoutePosition,
                    onRecenter: recenterOnRoute
                )
                .padding(.horizontal, 14)

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

    private func recenterOnRoute() {
        followsRoutePosition = true
        updateCamera()
    }

    private func updateCamera(animated: Bool = true) {
        guard followsRoutePosition else { return }

        let region = MKCoordinateRegion(
            center: model.currentCoordinate,
            span: mapZoomLevel.span
        )

        if animated {
            withAnimation(.easeInOut(duration: 0.55)) {
                cameraPosition = .region(region)
            }
        } else {
            cameraPosition = .region(region)
        }
    }
}

private enum MapZoomLevel: String, CaseIterable, Identifiable {
    case route
    case close
    case street

    var id: String { rawValue }

    var title: String {
        switch self {
        case .route: return "Route"
        case .close: return "Close"
        case .street: return "Street"
        }
    }

    var span: MKCoordinateSpan {
        switch self {
        case .route:
            return MKCoordinateSpan(latitudeDelta: 0.018, longitudeDelta: 0.018)
        case .close:
            return MKCoordinateSpan(latitudeDelta: 0.008, longitudeDelta: 0.008)
        case .street:
            return MKCoordinateSpan(latitudeDelta: 0.0035, longitudeDelta: 0.0035)
        }
    }
}

private struct MapCameraControls: View {
    @Binding var selection: MapZoomLevel
    let followsRoutePosition: Bool
    let onRecenter: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Picker("Map zoom", selection: $selection) {
                ForEach(MapZoomLevel.allCases) { zoomLevel in
                    Text(zoomLevel.title).tag(zoomLevel)
                }
            }
            .pickerStyle(.segmented)

            Button(action: onRecenter) {
                Image(systemName: followsRoutePosition ? "location.fill" : "location")
                    .font(.body.weight(.semibold))
                    .frame(width: 42, height: 34)
                    .accessibilityLabel(followsRoutePosition ? "Following route position" : "Recenter on route position")
            }
            .buttonStyle(.plain)
            .foregroundStyle(followsRoutePosition ? .cyan : .primary)
            .background(Color(.systemBackground).opacity(0.86), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.12), radius: 14, y: 7)
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

                    RealtimeStatusBadge(
                        state: model.realtimeStatus,
                        mode: model.guideVoiceMode,
                        fallbackMessage: model.fallbackErrorState
                    )
                }
                .frame(maxWidth: 190, alignment: .trailing)
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
    let state: RealtimeConnectionState
    let mode: GuideVoiceMode
    let fallbackMessage: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Label("GPT-Realtime-2 \(display.title)", systemImage: display.symbol)
                .font(.caption2.weight(.bold))
                .foregroundStyle(display.tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(display.tint.opacity(0.14), in: Capsule())

            Text(display.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.78)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("GPT-Realtime-2 \(display.title). \(display.detail)")
    }

    private var display: RealtimeStatusDisplay {
        RealtimeStatusDisplay(state: state, mode: mode, fallbackMessage: fallbackMessage)
    }
}

private struct RealtimeStatusDisplay {
    let title: String
    let detail: String
    let symbol: String
    let tint: Color

    init(state: RealtimeConnectionState, mode: GuideVoiceMode, fallbackMessage: String?) {
        switch state {
        case .connecting:
            self.init(
                title: "Connecting",
                detail: "Opening the live voice session",
                symbol: "antenna.radiowaves.left.and.right",
                tint: .blue
            )
        case .connected:
            self.init(
                title: "Connected",
                detail: "Realtime voice is ready",
                symbol: "checkmark.circle.fill",
                tint: .green
            )
        case .speaking:
            self.init(
                title: "Speaking",
                detail: "Speaking from compact route context",
                symbol: "waveform.circle.fill",
                tint: .cyan
            )
        case .fallback:
            self.init(
                title: "Fallback",
                detail: RealtimeStatusDisplay.fallbackDetail(from: fallbackMessage),
                symbol: "arrow.triangle.2.circlepath.circle.fill",
                tint: .orange
            )
        case .failed:
            self.init(
                title: "Error",
                detail: "Local voice fallback is active",
                symbol: "exclamationmark.triangle.fill",
                tint: .red
            )
        case .disconnected:
            self.init(
                title: mode == .realtime ? "Disconnected" : "Standby",
                detail: mode == .realtime ? "Realtime voice is offline" : "Local Guide selected",
                symbol: mode == .realtime ? "xmark.circle.fill" : "speaker.wave.2.fill",
                tint: .secondary
            )
        }
    }

    private init(title: String, detail: String, symbol: String, tint: Color) {
        self.title = title
        self.detail = detail
        self.symbol = symbol
        self.tint = tint
    }

    private static func fallbackDetail(from message: String?) -> String {
        let normalizedMessage = message?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased() ?? ""

        if normalizedMessage.contains("openai_api_key") || normalizedMessage.contains("api key") {
            return "No key. Local Guide fallback active"
        }

        return "Local Guide fallback active"
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

            GuideConversationRow(model: model)

            if showsAudit {
                AuditPanel(model: model)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 18, y: 10)
    }
}

private struct GuideConversationRow: View {
    @ObservedObject var model: DriveGuideModel
    @State private var isPressingMic = false

    private let demoCommand = DriveGuideModel.demoInterruptionText

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Button {} label: {
                    Image(systemName: model.isListeningForQuestion ? "mic.fill" : "mic.slash.fill")
                        .font(.caption.weight(.bold))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(.white)
                        .background(model.isListeningForQuestion ? .green : .secondary, in: Circle())
                        .accessibilityLabel(model.isListeningForQuestion ? "Release to finish voice turn" : "Hold to talk")
                }
                .buttonStyle(.plain)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { _ in
                            guard !isPressingMic else { return }
                            isPressingMic = true
                            model.beginVoiceQuestion()
                        }
                        .onEnded { _ in
                            guard isPressingMic else { return }
                            isPressingMic = false
                            model.finishVoiceQuestion()
                        }
                )

                TextField("Ask about this stretch", text: $model.questionDraft)
                    .textInputAutocapitalization(.sentences)
                    .submitLabel(.send)
                    .font(.caption)
                    .padding(.horizontal, 10)
                    .frame(minHeight: 34)
                    .background(Color(.systemBackground).opacity(0.72), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .onSubmit(model.submitQuestionDraft)

                Button {
                    model.submitQuestionDraft()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.caption.weight(.bold))
                        .frame(width: 34, height: 34)
                        .foregroundStyle(.cyan)
                        .accessibilityLabel("Send question")
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 8) {
                Image(systemName: model.isListeningForQuestion ? "waveform" : "mic.slash.fill")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(model.isListeningForQuestion ? .green : .secondary)

                Text(statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 4)

                Button {
                    model.sendCannedInterruption()
                } label: {
                    Label("History", systemImage: "hand.raised.fill")
                        .font(.caption2.weight(.semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.orange)
                .accessibilityLabel("Ask for the history angle")
            }
        }
        .padding(9)
        .background(Color(.secondarySystemBackground).opacity(0.82), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private var statusText: String {
        if model.lastUserUtterance == demoCommand {
            return "History angle sent"
        }

        if !model.voiceQuestionTranscript.isEmpty {
            return model.voiceQuestionTranscript
        }

        return model.voiceQuestionStatus
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
                    emptyText: "Waiting for GPT-Realtime-2 transcript",
                    systemImage: "text.bubble.fill",
                    tint: .cyan,
                    lineLimit: 4
                )
                AuditFieldRow(
                    title: "User utterance",
                    value: model.lastUserUtterance,
                    emptyText: "No interruption sent",
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
                    emptyText: "Route context will appear when the guide starts",
                    systemImage: "doc.text.magnifyingglass",
                    tint: .purple,
                    lineLimit: 4
                )
                AuditFieldRow(
                    title: "Fallback / error",
                    value: model.fallbackErrorState,
                    emptyText: "No fallback active",
                    systemImage: "exclamationmark.triangle.fill",
                    tint: .orange,
                    lineLimit: 3,
                    valueTransform: Self.fallbackDisplayValue
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

    private static func fallbackDisplayValue(_ value: String) -> String {
        let normalizedValue = value.lowercased()

        if normalizedValue.contains("openai_api_key") || normalizedValue.contains("api key") {
            return "No OPENAI_API_KEY found. Local Guide fallback is speaking the route."
        }

        if normalizedValue.contains("websocket") || normalizedValue.contains("network") {
            return "Realtime connection failed. Local Guide fallback is speaking the route."
        }

        return value
    }
}

private struct AuditFieldRow: View {
    let title: String
    let value: String?
    let emptyText: String
    let systemImage: String
    let tint: Color
    var lineLimit = 2
    var valueTransform: (String) -> String = { $0 }

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
                    .lineLimit(lineLimit)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }

    private var displayValue: String {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? emptyText : valueTransform(trimmed)
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
