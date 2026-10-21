# 大鱼人像美化 · beatygril

基于本仓库的 FxPlug4 初始工程制作的人像美化滤镜，支持 Motion 和 Final Cut Pro。源码使用 Objective-C、Vision、Core Image 与 Metal。

功能包括磨皮、肤色、细节、牙齿美白、眼睛提亮、九类脸型调整、画面选脸、三目标分析跟踪扩展和蒙版预览。原版 MSE18V2 的静态分析依据、近似实现与尚未对齐的部分见 [分析说明](docs/analysis/REA-分析与复刻说明.md)。本版尚未完成原版逐像素与复杂运动跟踪对照。

## 使用

正式安装路径为 `/Library/Plug-Ins/FxPlug/beatygril.app`。Motion 滤镜分类为「大鱼」，滤镜名「大鱼人像美化」。Final Cut Pro 在「效果 → 大鱼 → 大鱼人像美化」中使用配套 Motion 效果，模板目录必须同时保留 `.moef` 与 `Drop Zone.tiff`。先调高中频磨皮，再按需调肤色与脸型；勾选「只处理选中人脸」可在画面点击选脸，随后选择跟踪目标、向前/向后分析，数据随工程保存。

## 开发和恢复

需要 Xcode 27.1、FxPlug SDK 4.3.4 与 PluginManager 1.7.4；最低运行系统 macOS 13。正式产物为 arm64/x86_64 通用版本。

```sh
./scripts/test.sh
PAINTFCP_HOST_ASAN=1 ./scripts/test-host.sh
PAINTFCP_OSC_ASAN=1 ./scripts/test-osc.sh
xcodebuild -project beatygril/beatygril.xcodeproj -scheme 'Wrapper Application' -configuration Release -derivedDataPath /tmp/paintfcp-build -destination 'generic/platform=macOS' build
```

工程从 `/Library/Developer/SDKs/FxPlug.sdk` 读取头文件与链接信息，从 `/Library/Developer/Frameworks` 嵌入可运行的 Apple 框架。构建默认使用团队 B3W25FX5H5 的 Developer ID Application 身份；正式交付使用 `python3 scripts/deliver.py` 完成公证、粘附和安装；安装前先关闭 Motion 与 FCP，脚本在检测到宿主仍运行时保留原安装版并停止。原生验收完成后继续脚本的清理阶段，清除临时注册与 APP 副本。

私有源码仓库：`https://dayu.media/git/dayu/paintfcp-fxplug.git`。恢复入口见 [RECOVERY.md](RECOVERY.md)，当前验证记录见 [验证记录](docs/验证记录.md)。原始模板保存在 `baseline-20261021` 标签。
