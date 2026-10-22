# 大鱼人像美化 · beatygril

基于本仓库的 FxPlug4 初始工程制作的人像美化滤镜，支持 Motion 和 Final Cut Pro。源码使用 Objective-C、Vision、Core Image 与 Metal。

代码由 OpenAI + Codex 全程编写，站长仅参与调试和测试。

功能包括磨皮、肤色、细节、牙齿美白、眼睛提亮、九类脸型调整、自动人脸跟随和多人处理。原版 MSE18V2 的静态分析依据、近似实现与尚未对齐的部分见 [分析说明](docs/analysis/REA-分析与复刻说明.md)。本版尚未完成原版逐像素与复杂运动跟踪对照。

## 使用

正式安装路径为 `/Library/Plug-Ins/FxPlug/beatygril.app`。Motion 滤镜分类为「大鱼」，滤镜名「大鱼人像美化」。Final Cut Pro 在「效果 → 大鱼磨皮瘦脸 → 大鱼人像美化」中使用配套 Motion 效果，模板目录必须同时保留 `.moef` 与 `Drop Zone.tiff`。美化会随当前帧的人脸自动更新，不需要点击分析。界面以磨皮、美白、瘦脸三张卡片呈现，默认跟随主要人脸；多人模式对多脸变形。单项眼睛可暂时停用并保留数值，右侧箭头恢复默认；磨皮半径、饱和度、锐化和整体混合等收在「更多设置」。旧手动分析与调试参数仅保留隐藏兼容，实际输出统一使用实时自动跟随。

1.3.0 的磨皮卡片依次提供「磨皮程度、微细锐化、五官保护、非肤色区保护」。两种保护默认 100%；降低五官保护让五官区域参与更多磨皮，降低非肤色区保护则扩大磨皮范围，均不扩大肤色提亮范围。微细锐化在局部支持区域恢复纹理；旧全局磨皮和全局锐化仍保留在更多设置，旧工程的参数与归档继续兼容。迁移证据、实现边界与验证见[新版磨皮参数迁移](docs/analysis/新版磨皮参数迁移.md)。1.3.0（15）APP 已完成签名、公证及正式安装，1636 项自动检查通过；原生宿主效果由用户实测。1.2.0 下载链接仍对应原发行包，本次未更新文章或安装包。

## 开发和恢复

需要 Xcode 27.1、FxPlug SDK 4.3.4 与 PluginManager 1.7.4；最低运行系统 macOS 13。正式产物为 arm64/x86_64 通用版本。

```sh
./scripts/test.sh
PAINTFCP_HOST_ASAN=1 ./scripts/test-host.sh
PAINTFCP_OSC_ASAN=1 ./scripts/test-osc.sh
xcodebuild -project beatygril/beatygril.xcodeproj -scheme 'Wrapper Application' -configuration Release -derivedDataPath /tmp/paintfcp-build -destination 'generic/platform=macOS' build
```

工程从 `/Library/Developer/SDKs/FxPlug.sdk` 读取头文件与链接信息，从 `/Library/Developer/Frameworks` 嵌入可运行的 Apple 框架。构建默认使用团队 B3W25FX5H5 的 Developer ID Application 身份；正式交付使用 `python3 scripts/deliver.py` 完成公证、粘附和安装；安装前先关闭 Motion 与 FCP，脚本在检测到宿主仍运行时保留原安装版并停止。原生验收完成后继续脚本的清理阶段，清除临时注册与 APP 副本。

公开源码：[GitHub · FCP-BeatyGril](https://github.com/FAMEDaYu/FCP-BeatyGril)。大鱼站备份：`https://dayu.media/git/dayu/paintfcp-fxplug.git`。恢复入口见 [RECOVERY.md](RECOVERY.md)，当前验证记录见 [验证记录](docs/验证记录.md)。原始模板保存在 `baseline-20261021` 标签。

继续开发或移交时先读[项目交接文档](docs/项目交接.md)，包含当前发布状态、源码入口、坐标与交互约定、验收边界，以及签名打包和双远端保存流程。

## 1.0.5 瘦脸修复

瘦脸现固定使用Vision revision 3的76点配置，以17组轮廓到鼻部/瞳孔锚点的局部逆向采样替代脸框水平挤压，包含原版尺寸增益与滑块强度映射。完整点阵贯通实时稳定与离线存储；旧分析记录没有完整76点时跳过瘦脸，重新分析可补齐。其他脸型项仍使用原有近似实现，不能将本次对齐扩张为全部脸型逐像素等价。

离屏验证新增224项：含48组脸部投影/尺寸/歪头与独立17-pin数值场对照、数据恢复和缺点保护；完整回归604项通过。Motion/FCP界面由用户自测。可运行 `python3 scripts/deliver.py --wait-for-hosts --user-tests`，签名公证后只读等待宿主自然退出，安装验证与清理无需操作宿主界面。

## 1.0.6 下巴与图像坐标修复

下巴改为76点中68→38、67→37、66→36的三组局部位移，正值上收、负值延伸，保留原版正负不同系数及尺寸增益。Core Image/IOSurface输入输出移除按TOP_LEFT额外翻转，和原版图像链对齐。修复依据与离屏复现见[下巴与坐标分析](docs/analysis/下巴与坐标分析.md)。七类其余脸型项仍是近似实现。

旧版分析记录无法区分是否包含额外翻转，新版保留原字符串但暂用实时跟随；重新分析即可写入新坐标标记并恢复离线跟踪。最终Motion/FCP画面由用户自行测试。

1.0.6（8）已完成正式签名、Apple公证、票据、安装和模板同步。904项完整回归及独立远程恢复核验通过；最终宿主视觉由用户自测。交付回执在`docs/verification/v1.0.6/`，恢复标签为`v1.0.6`。

## 1.1.0 原生卡片面板

使用AppKit自绘卡片、滑块和开关，原生数值输入、肤色圆点、单项/分组启停及重置。FCP仅发布自定义面板210和两项版权信息，撤掉平铺参数与手动分析板块。新面板使用独立NSSecureCoding状态对象完整保存设置，支持复制、撤销数据和数值插值；未编辑时保持旧文档参数值。旧分析数据不参与实时渲染。

`./scripts/test-inspector.sh`验证参数路由、保存恢复、事务、绕过/重置和离屏布局；`python3 scripts/inspector-template.py audit Templates/大鱼人像美化/大鱼人像美化.moef`验证模板自定义数据和发布入口。离屏截图和模拟宿主检查不能替代Motion/FCP的实际嵌入、键盘/VoiceOver和工程重开验收，仍由用户自测。完整1039项回归通过，Inspector/宿主适配/OSC启用ASan。离屏演示图见[面板预览](docs/verification/v1.1.0/inspector-preview.png)。1.1.0（9）已完成通用Release正式签名、Apple公证、票据粘附、唯一正式目录安装及配套模板同步。签名源码`f79d24eb0185f31feaae58b83b632f92dcb3ca91`的111文件及16项必要资源已独立远端恢复核验，clone内134项Inspector ASan和模板审计通过。

正式安装回执见`docs/verification/v1.1.0/installed-verification.json`，恢复标签为`v1.1.0`。签名、票据、Gatekeeper、双架构身份、PluginKit正式路径及配套模板字节核验通过；已清理本次临时APP、旧APP备份和公证ZIP。有界扫描只发现正式路径的产品外层APP，未把该范围表述为所有卷的完整扫描。未操作Motion/FCP界面，实际面板嵌入与工程重开由用户自测。

## 1.1.2 面板交互与下半脸定位修复

面板改为先在真实视图的宿主 action 内取得读写接口，修复控件一直禁用的问题。短脸改用76点下半脸闭合区域和鼻梁位移轴，下颌骨改为六组相邻轮廓半径的局部位移，移除旧脸框近似场；详见[分析](docs/analysis/短脸与下颌骨分析.md)。其余五项脸型仍保留近似实现，不能将局部算法恢复视为全部效果逐像素一致。

1551项回归通过，含335项宿主适配、98项OSC和157项面板ASan检查；28种控制/原点组合均核验实际解剖位置，改变原点标签时逐字节一致。额外真实帧ASan专项886项通过，含重复基础用例。1.1.2（13）已完成正式签名、公证、票据、唯一正式路径安装及副本清理。Motion/FCP原生数值、重置和隔离画面响应已验证，Motion保存重开与撤销通过；用户于2026-10-22实测确认“拖动中已持续更新”；未指定测试宿主，不扩张为两个宿主分别完成动态排帧验收。连续步进在松手前提交已通过独立模拟宿主验证，不能将它等同于每个鼠标事件都排出一帧。

## 1.2.0 免费开源发布

采用 MIT 许可（第三方资源边界见 THIRD_PARTY_NOTICES.md）。安装包同时包含唯一正式 FxPlug4 APP 和 FCP 效果模板；自动注册，无需账号、激活码或付费激活。主 APP 显示古风说明图，窗口显示三秒后自动退出，不影响独立的宿主插件服务。封面人物是生成的宣传插画，非效果前后对比。

`large.png`（640×360）和 `small.png`（192×108）与 `.moef` 同目录，安装器安装后重新锁定。手动复制或从 Git 恢复模板时，需对这两个 PNG 重新执行 `chflags uchg`，不能锁定整个模板目录。FCP 当前分类为「大鱼磨皮瘦脸」，Motion 原生滤镜分类仍为「大鱼」。

GitHub 提供公开源码、提交历史和版本标签；[1.2.0 Release](https://github.com/FAMEDaYu/FCP-BeatyGril/releases/tag/v1.2.0) 提供正式签名公证安装包。大鱼站 Git 备份仍受站点登录与会员网关限制，发布文章另提供公开源码快照；安装包始终免费。
