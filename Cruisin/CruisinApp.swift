import SwiftUI

@main
struct CruisinApp: App {
    @StateObject private var guide = DriveGuideModel()

    var body: some Scene {
        WindowGroup {
            DrivingExperienceView(model: guide)
        }
    }
}
