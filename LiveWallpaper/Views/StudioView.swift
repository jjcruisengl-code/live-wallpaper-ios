import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct StudioView: View {
    @ObservedObject var studio: WallpaperStudio
    @State private var pickedVideo: PhotosPickerItem?
    @State private var showFiles = false
    @State private var showGuide = false
    @State private var showFullScreen = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    intro
                    preview
                    importButtons
                    if let source = studio.source {
                        clipEditor(source)
                        soundControls(source)
                        exportButton
                    }
                    capabilities
                }
                .padding(20)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            }
            .background(Color(red: 0.035, green: 0.045, blue: 0.065))
            .navigationTitle("流光壁纸")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showGuide = true } label: { Image(systemName: "questionmark.circle") }
                        .accessibilityLabel("查看设置锁屏的方法")
                }
            }
            .sheet(isPresented: $showGuide) { WallpaperGuideView() }
            .fullScreenCover(isPresented: $showFullScreen) { fullScreenPreview }
            .fileImporter(isPresented: $showFiles, allowedContentTypes: [.movie, .video]) { result in
                switch result {
                case .success(let url): Task { await studio.importFile(url) }
                case .failure(let error): studio.errorMessage = error.localizedDescription
                }
            }
            .onChange(of: pickedVideo) { _, item in
                guard let item else { return }
                Task {
                    await studio.importPhoto(item)
                    pickedVideo = nil
                }
            }
            .alert("操作未完成", isPresented: Binding(
                get: { studio.errorMessage != nil },
                set: { if !$0 { studio.errorMessage = nil } }
            )) {
                Button("知道了", role: .cancel) { studio.errorMessage = nil }
            } message: { Text(studio.errorMessage ?? "请重试。") }
            .alert("已保存到相册", isPresented: $studio.showExportSuccess) {
                Button("查看设置步骤") { showGuide = true }
                Button("稍后", role: .cancel) { }
            } message: {
                Text("Live Photo 已保存。请到系统墙纸编辑器选择它；是否支持锁屏动态效果，以 iPhone 实际结果为准。")
            }
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("让喜欢的瞬间，\n留在每一次亮屏。")
                .font(.system(.largeTitle, design: .rounded, weight: .bold))
            Text("视频片段 · 循环预览 · Live Photo 导出")
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private var preview: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28).fill(
                LinearGradient(colors: [.indigo.opacity(0.65), .black, .teal.opacity(0.35)], startPoint: .topLeading, endPoint: .bottomTrailing)
            )
            if studio.source != nil {
                if !showFullScreen {
                    PlayerSurface(player: studio.playback.player)
                        .clipShape(RoundedRectangle(cornerRadius: 28))
                }
                VStack {
                    HStack {
                        Label("App 内循环预览", systemImage: "repeat")
                            .font(.caption.weight(.medium))
                            .padding(10).background(.ultraThinMaterial, in: Capsule())
                        Spacer()
                    }
                    Spacer()
                    HStack {
                        Spacer()
                        Button { showFullScreen = true } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .padding(14).background(.ultraThinMaterial, in: Circle())
                        }
                        .accessibilityLabel("全屏预览视频")
                        .disabled(studio.isBusy)
                    }
                }.padding(16)
            } else {
                VStack(spacing: 14) {
                    Image(systemName: "livephoto").font(.system(size: 64, weight: .ultraLight)).foregroundStyle(.mint)
                    Text("你的下一张动态锁屏").font(.headline)
                    Text("导入一段视频，从喜欢的瞬间开始")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding()
            }
            if studio.isImporting {
                ProgressView("正在读取视频…")
                    .padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .frame(height: 365)
        .overlay(RoundedRectangle(cornerRadius: 28).strokeBorder(.white.opacity(0.1)))
        .accessibilityElement(children: .contain)
    }

    private var importButtons: some View {
        HStack(spacing: 12) {
            PhotosPicker(selection: $pickedVideo, matching: .videos, preferredItemEncoding: .current) {
                Label("相册视频", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }.buttonStyle(.borderedProminent)
            Button { showFiles = true } label: {
                Label("文件", systemImage: "folder").frame(maxWidth: .infinity)
            }.buttonStyle(.bordered)
        }
        .controlSize(.large)
        .disabled(studio.isBusy)
    }

    private func clipEditor(_ source: VideoSource) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("选择片段", systemImage: "slider.horizontal.3").font(.headline)
            Text("\(source.title) · 原视频 \(source.duration.formatted(.number.precision(.fractionLength(1)))) 秒")
                .font(.caption).foregroundStyle(.secondary).lineLimit(2)
            HStack {
                Text("开始位置")
                Spacer()
                Text("\(studio.settings.startSeconds.formatted(.number.precision(.fractionLength(1)))) 秒").monospacedDigit()
            }
            let maxStart = max(0, source.duration - studio.settings.durationSeconds)
            Slider(value: $studio.settings.startSeconds, in: 0...max(0.001, maxStart), onEditingChanged: { editing in
                if !editing { studio.updateClip() }
            })
            .disabled(maxStart <= 0)
            .accessibilityLabel("片段开始时间")
            HStack {
                Text("片段时长")
                Spacer()
                Text("\(studio.settings.durationSeconds.formatted(.number.precision(.fractionLength(1)))) 秒").monospacedDigit()
            }
            Slider(value: $studio.settings.durationSeconds,
                   in: WallpaperSettings.minimumClipDuration...max(0.501, min(source.duration, WallpaperSettings.maximumClipDuration)),
                   onEditingChanged: { editing in if !editing { studio.updateClip() } })
                .disabled(source.duration <= WallpaperSettings.minimumClipDuration)
                .accessibilityLabel("片段时长")
            Text("最多 3 秒，原比例导出。松开滑块后更新预览；墙纸位置可在系统中调整。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(18).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
        .disabled(studio.isBusy)
    }

    private func soundControls(_ source: VideoSource) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("预览声音", isOn: $studio.settings.previewSoundEnabled)
                .onChange(of: studio.settings.previewSoundEnabled) { _, _ in studio.updateSound() }
            Toggle("导出保留声音", isOn: $studio.settings.includeAudio)
                .onChange(of: studio.settings.includeAudio) { _, _ in studio.saveProject() }
            Text(source.hasAudio
                 ? "声音开关分别作用于 App 预览和相册中的 Live Photo；系统锁屏不播放壁纸声音。"
                 : "这个视频没有音轨。")
                .font(.caption).foregroundStyle(.secondary)
            AudioStatusView(playback: studio.playback)
        }
        .padding(18).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 20))
        .disabled(studio.isBusy || !source.hasAudio)
    }

    private var exportButton: some View {
        VStack(spacing: 10) {
            Button { Task { await studio.export() } } label: {
                HStack {
                    if studio.isExporting { ProgressView().tint(.black) }
                    Label(studio.isExporting ? "正在制作 Live Photo…" : "导出 Live Photo 到相册", systemImage: "square.and.arrow.down")
                }.frame(maxWidth: .infinity).padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent).controlSize(.large)
            .disabled(studio.isBusy)
            Text(studio.isExporting ? "请保持 App 在前台，完成后会提示。" : "首次导出需要允许添加照片，无需开放整个相册。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var capabilities: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("关于系统锁屏", systemImage: "info.circle").font(.subheadline.weight(.semibold))
            Text("支持的 Live Photo 可在点亮屏幕时播放。持续循环、有声播放仅适用于 App 内；动态锁屏兼容性由 iOS 判断。")
                .font(.caption).foregroundStyle(.secondary)
            Button("查看设置方法") { showGuide = true }.font(.subheadline)
        }
    }

    private var fullScreenPreview: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            PlayerSurface(player: studio.playback.player).ignoresSafeArea()
            VStack(alignment: .trailing, spacing: 16) {
                Button { showFullScreen = false } label: {
                    Label("返回", systemImage: "xmark").padding(12).background(.ultraThinMaterial, in: Capsule())
                }
                Button {
                    studio.settings.previewSoundEnabled.toggle()
                    studio.updateSound()
                } label: {
                    Image(systemName: studio.settings.previewSoundEnabled ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .padding(14).background(.ultraThinMaterial, in: Circle())
                }
                .disabled(studio.source?.hasAudio != true)
                .accessibilityLabel(studio.settings.previewSoundEnabled ? "关闭预览声音" : "打开预览声音")
                Spacer()
                Text("App 内预览").font(.caption).foregroundStyle(.secondary)
            }.padding(24)
        }
    }
}

private struct AudioStatusView: View {
    @ObservedObject var playback: LoopingPlayer
    var body: some View {
        if let message = playback.audioError {
            Text(message).font(.caption).foregroundStyle(.orange)
        }
    }
}
