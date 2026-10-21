# 大鱼人像美化 · beatygril

基于本仓库的 FxPlug4 初始工程制作的人像美化滤镜，支持 Motion 和 Final Cut Pro。源码使用 Objective-C、Vision、Core Image 与 Metal。

功能包括磨皮、肤色、细节、牙齿美白、眼睛提亮、九类脸型调整、自动人脸跟随和多人处理。原版 MSE18V2 的静态分析依据、近似实现与尚未对齐的部分见 [分析说明](docs/analysis/REA-分析与复刻说明.md)。本版尚未完成原版逐像素与复杂运动跟踪对照。

## 使用

正式安装路径为 `/Library/Plug-Ins/FxPlug/beatygril.app`。Motion 滤镜分类为「大鱼」，滤镜名「大鱼人像美化」。Final Cut Pro 在「效果 → 大鱼 → 大鱼人像美化」中使用配套 Motion 效果，模板目录必须同时保留 `.moef` 与 `Drop Zone.tiff`。美化会随当前帧的人脸自动更新，不需要点击分析。界面以磨皮、美白、瘦脸三张卡片呈现，默认跟随主要人脸；多人模式对多脸变形。单项眼睛可暂时停用并保留数值，右侧箭头恢复默认；磨皮半径、饱和度、锐化和整体混合等收在「更多设置」。旧手动分析与调试参数仅保留隐藏兼容，实际输出统一使用实时自动跟随。

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

## 1.0.5 瘦脸修复

瘦脸现固定使用Vision revision 3的76点配置，以17组轮廓到鼻部/瞳孔锚点的局部逆向采样替代脸框水平挤压，包含原版尺寸增益与滑块强度映射。完整点阵贯通实时稳定与离线存储；旧分析记录没有完整76点时跳过瘦脸，重新分析可补齐。其他脸型项仍使用原有近似实现，不能将本次对齐扩张为全部脸型逐像素等价。

离屏验证新增224项：含48组脸部投影/尺寸/歪头与独立17-pin数值场对照、数据恢复和缺点保护；完整回归604项通过。Motion/FCP界面由用户自测。可运行 `python3 scripts/deliver.py --wait-for-hosts --user-tests`，签名公证后只读等待宿主自然退出，安装验证与清理无需操作宿主界面。

## 1.0.6 下巴与图像坐标修复

下巴改为76点中68→38、67→37、66→36的三组局部位移，正值上收、负值延伸，保留原版正负不同系数及尺寸增益。Core Image/IOSurface输入输出移除按TOP_LEFT额外翻转，和原版图像链对齐。修复依据与离屏复现见[下巴与坐标分析](docs/analysis/下巴与坐标分析.md)。七类其余脸型项仍是近似实现。

旧版分析记录无法区分是否包含额外翻转，新版保留原字符串但暂用实时跟随；重新分析即可写入新坐标标记并恢复离线跟踪。最终Motion/FCP画面由用户自行测试。

1.0.6（8）已完成正式签名、Apple公证、票据、安装和模板同步。904项完整回归及独立远程恢复核验通过；最终宿主视觉由用户自测。交付回执在`docs/verification/v1.0.6/`，恢复标签为`v1.0.6`。

## 1.1.0 原生卡片面板

使用AppKit自绘卡片、滑块和开关，原生数值输入、肤色圆点、单项/分组启停及重置。FCP仅发布自定义面板210和两项版权信息，撤掉平铺参数与手动分析板块。新面板使用独立NSSecureCoding状态对象完整保存设置，支持复制、撤销数据和数值插值；未编辑时保持旧文档参数值。旧分析数据不参与实时渲染。

`./scripts/test-inspector.sh`验证参数路由、保存恢复、事务、绕过/重置和离屏布局；`python3 scripts/inspector-template.py audit Templates/大鱼人像美化/大鱼人像美化.moef`验证模板自定义数据和发布入口。离屏截图和模拟宿主检查不能替代Motion/FCP的实际嵌入、键盘/VoiceOver和工程重开验收，仍由用户自测。完整1039项回归通过，Inspector/宿主适配/OSC启用ASan。离屏演示图见[面板预览](docs/verification/v1.1.0/inspector-preview.png)。1.1.0（9）已通过正式签名、Apple公证和票据验证；当前等待用户自行退出Motion/FCP后安装。签名源码`f79d24eb0185f31feaae58b83b632f92dcb3ca91`的111文件及16项必要资源已独立远端恢复核验，clone内134项Inspector ASan和模板审计通过。
