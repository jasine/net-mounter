import SwiftUI

/// 包装视图：当 popover 不可见时，整个 ServerListView 都不会被渲染
/// 这确保了所有视图被销毁、所有 Combine 订阅被取消、所有动画被停止
struct PopoverContentView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var autoMountService: AutoMountService

    var body: some View {
        Group {
            if appState.isUIVisible {
                ServerListView()
            } else {
                // 空视图：不消耗任何 CPU/GPU 资源
                Color.clear
                    .frame(width: 320, height: 400)
            }
        }
    }
}
