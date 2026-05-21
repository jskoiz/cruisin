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

                Label(model.isRunning ? "Live replay" : "Paused", systemImage: model.isRunning ? "waveform.circle.fill" : "pause.circle")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(model.isRunning ? .green : .orange)
                    .labelStyle(.titleAndIcon)
            }

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

            if showsAudit {
                AuditPanel(model: model)
            }
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.16), radius: 18, y: 10)
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
