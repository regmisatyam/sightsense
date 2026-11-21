import SwiftUI

@main
struct SightSenseApp: App {
    @State private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let settings = Settings()
        // Another camera later (e.g. glasses) plugs in here. `-replay <folder>` plays back a recorded walk.
        let camera: any FrameSource = ReplayFrameSource.fromLaunchArguments()
            ?? PhoneCameraSource(preferUltraWide: settings.wideCamera)
        _model = State(initialValue: AppModel(settings: settings, camera: camera))
    }

    var body: some Scene {
        WindowGroup {
            RootView(model: model)
                .onAppear { model.start() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: model.didEnterBackground()
            case .active: model.didBecomeActive()
            default: break
            }
        }
    }
}
