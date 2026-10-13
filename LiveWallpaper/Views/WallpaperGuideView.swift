import SwiftUI

struct WallpaperGuideView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section("设置动态锁屏") {
                    Label("先将视频片段导出为 Live Photo，保存到相册。", systemImage: "1.circle.fill")
                    Label("打开系统「设置」→「墙纸」→「添加新墙纸」。", systemImage: "2.circle.fill")
                    Label("选择「照片」→「实况照片」，找到刚保存的素材。", systemImage: "3.circle.fill")
                    Label("如果系统支持该素材的动态效果，打开实况播放按钮，再添加墙纸。", systemImage: "4.circle.fill")
                    Label("锁定 iPhone，再点亮屏幕，检查动态效果。", systemImage: "5.circle.fill")
                }
                Section("两种播放方式") {
                    Label("App 内：片段循环播放，可随时开关声音。", systemImage: "repeat")
                    Label("系统锁屏：由 iOS 控制唤醒动画，App 无法开启持续循环或壁纸声音。", systemImage: "lock")
                    Label("主屏幕：使用静态画面。", systemImage: "apps.iphone")
                }
                Section("如果显示「不支持动态效果」") {
                    Text("能在相册中播放的 Live Photo，不一定能用作动态锁屏。苹果还会判断素材是否适合转换为慢动作；系统没有提供提前保证兼容的接口。")
                    Text("可尝试更平稳、主体清晰的短片段，再到系统墙纸编辑器检查。也可以用相机拍摄的实况照片测试系统的唤醒播放功能。")
                }
                Section("声音设置") {
                    Text("「预览声音」只控制当前 App 的播放。「导出保留声音」决定相册中 Live Photo 是否包含音轨，不会开启锁屏声音。")
                }
                Section {
                    Link("Apple：将实况照片设为锁屏墙纸", destination: URL(string: "https://support.apple.com/zh-cn/120734")!)
                    Link("Apple：iOS 26 锁定屏幕使用手册", destination: URL(string: "https://support.apple.com/guide/iphone/iph4d0e6c351/26/ios/26")!)
                }
            }
            .navigationTitle("设置锁屏")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}
