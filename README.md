# 流光壁纸 · iOS 原生原型

面向 iPhone 17 Pro / iOS 26.4.2 的 SwiftUI 视频壁纸制作工具，最低支持 iOS 17。当前交付的是第一版源码和云构建配置；尚未经过 Apple SDK 编译、签名或真机验证。

## 已实现的代码范围

- 从系统照片选择器或「文件」导入视频，不读取整个相册。
- 选择 0.5–3 秒片段，App 内循环预览和全屏预览。
- 独立控制预览声音、导出素材是否包含声音。
- 自动保存当前视频和片段设置；替换时移除旧的本地视频。
- App 不活跃时暂停预览，回来后恢复；处理音频中断和耳机断开。
- 转换为 Live Photo：H.264 MOV 与 JPEG 配对，写入共享标识和静态帧时间元数据，验证配对后以仅添加权限保存到相册。
- 保留画面比例和方向，输出最高为旋转后的 1920 × 1080 范围、30 fps、SDR BT.709；横屏视频可在系统墙纸编辑器中调整位置。
- 中文界面、权限和失败提示、系统锁屏设置指引。

## 系统能力边界

| 需求 | 实际范围 |
| --- | --- |
| 视频持续循环 | App 前台预览支持 |
| 声音开关 | App 预览、相册中的导出素材支持 |
| 点亮屏幕自动播放 | 系统支持的 Live Photo 锁屏由 iOS 播放唤醒动画 |
| 锁屏持续循环视频并发声 | 普通 App 的公开 API 无法实现 |
| 自动替换系统墙纸 | 本版导出后由用户在系统中设置 |
| 主屏幕连续视频壁纸 | 普通 App 无法实现 |

**相册识别 Live Photo，不代表系统允许它作为动态锁屏。** Apple 的 iOS 26 手册要求素材适合转换为慢动作效果，实际兼容性只能在墙纸编辑器和真机亮屏时检查。应用不会把保存成功提示成设置墙纸成功。3 秒是本产品的导出上限，不是锁屏兼容保证。

参考：[Apple 设置 Live Photo 墙纸](https://support.apple.com/zh-cn/120734)、[iOS 26 锁屏手册](https://support.apple.com/guide/iphone/create-a-custom-lock-screen-iph4d0e6c351/26/ios/26)。

## 没有 Mac：云构建与免费安装路径

本项目不需要第三方 Swift 包。`.github/workflows/ios-build.yml` 使用 GitHub 的 macOS runner 编译，运行 XCTest，并在成功后生成未签名的真机 IPA。**未签名 IPA 不能直接在 iPhone 上打开安装**；模拟器 `.app` 也不能安装到手机。

1. 将此目录的内容放到自己的 GitHub 仓库根目录，包含隐藏的 `.github` 目录；不要仅把 ZIP 压缩包上传为一个文件。可使用私有仓库。
2. 在仓库的 Actions 页面运行 iOS 工作流，检查编译和测试日志。首次编译可能暴露只有 Apple SDK 才能检查的问题，应先修复这些问题。
3. 构建成功后下载名称带 `unsigned` 的 artifact，解压取得 `LiveWallpaper-unsigned.ipa`。
4. 如果有 Windows 电脑，可从 [Sideloadly 官方网站](https://sideloadly.io/)安装该工具及其官方指南要求的 Apple 驱动，用 USB 连接 iPhone、信任电脑，再使用自己的免费 Apple 账号对 IPA 签名安装。账号凭据在本地工具中输入，不属于本项目或 GitHub Actions 配置。
5. 按系统提示信任开发者并启用开发者模式。免费签名通常每 7 天需要刷新；保持相同账号和 App 标识可覆盖更新。该安装方法的 iOS 26.4.2 兼容性须实测。

[Sideloadly FAQ](https://sideloadly.io/faq.html)说明支持 Windows、免费账号及 iOS 26+，但这不是 Apple 官方的 Windows Xcode 工作流。只有 Linux 或只有 iPhone 时，本项目尚未提供经过验证的免费本地签名路径；需要可用的 Windows/Mac 签名环境。TestFlight 分发需要加入 Apple Developer Program，本版不依赖该付费路径。

GitHub 公共仓库的标准 runner 可免费使用；私有仓库消耗账户包含的分钟数和存储额度，超过额度可能计费。应按自己的账户预算运行；本项目不会自动购买算力、配置支付或上传账号证书。[GitHub Actions 计费说明](https://docs.github.com/en/billing/concepts/product-billing/github-actions)

截至本次交付，仅已准备工作流，没有推送仓库、实际运行云构建或生成真实 IPA。后续需要用户的 GitHub 仓库及访问授权。

## 有 Mac 时直接运行

1. 安装能支持目标设备的 Xcode。按 [Apple 官方兼容矩阵](https://developer.apple.com/xcode/system-requirements)选择版本；iOS 26.4 SDK 可使用 Xcode 26.4.1，该版本要求兼容的 macOS Tahoe。
2. 打开 `LiveWallpaper.xcodeproj`，选择 `LiveWallpaper` scheme。
3. 在 Target → Signing & Capabilities 中选自己的 Team，并把 `com.example.LiveWallpaper` 改为自己的唯一 Bundle ID。
4. 连接 iPhone，在手机上信任电脑，开启「设置 → 隐私与安全性 → 开发者模式」。在 Xcode 选择该设备并 Run。

模拟器构建与测试不需要开发者签名：

```sh
./scripts/build-ios.sh
./scripts/build-ios.sh --test
```

可以用 `IOS_TEST_DESTINATION='platform=iOS Simulator,name=iPhone 17 Pro'` 指定已安装的模拟器。仅需打包待本地签名的真机 IPA 时，在 macOS 运行 `./scripts/build-unsigned-ipa.sh`。

## 验证状态

- Linux：Xcode 工程对象引用、全部源码引用、scheme、Info.plist、隐私声明、资源 JSON 检查通过；构建脚本进行了 shell 语法检查。
- Swift：9 个文件的语法树检查未报错；导出器的两处 `.success(())` 被第三方解析器报告为缺失节点，经审查属于空元组语法解析限制，该解析器的错误节点遍历也出现崩溃。因此不把语法检查当作编译通过；Apple SDK 类型检查、链接和执行仍待完成。
- 已提供 7 个 XCTest，覆盖片段超界、短源文件、非有限时间和声音设置保留；需在云端或 Mac 运行，当前未宣称测试通过。
- 尚待验证：iOS 编译、视频解码/转码、Photos 实际保存、iOS 26.4.2 动态锁屏资格和亮屏效果、真机安装。

可随时执行静态工程检查：

```sh
python3 scripts/verify_project.py
```

## 真机验收

1. 导入竖屏、横屏、HDR、有声及无声 MP4/MOV；确认方向、比例、色彩、声音和连续循环至少 5 次。
2. 移动片段到视频末尾；确认预览与导出范围一致。导入不足 0.5 秒、损坏或无法访问的文件，检查错误提示。
3. 在有声预览中锁屏、回到主屏幕、接听电话、拔出耳机；确认停止/恢复符合界面设置，拔耳机后不会因拖动片段而突然从扬声器播放。
4. 初次导出拒绝相册权限，再允许后重试；验证在照片 App 中出现一个 Live Photo，封面正确，有声和无声导出分别符合选择。
5. 单独记录墙纸编辑器是否允许动态效果。不能以第 4 步成功替代这一步。
6. 设置支持的素材为锁屏，关闭再点亮屏幕，检查系统唤醒动画。不会出现持续循环或壁纸声音。
7. 重新启动 App，检查当前素材和设置恢复；更换素材后检查旧的 App 内文件已释放。

第一版没有内置视频库、直接导入原生 Live Photo、画面裁剪编辑器或正式应用图标，也没有 App Store 发布配置。视频只在设备上处理，未接入服务器、广告或统计 SDK。
