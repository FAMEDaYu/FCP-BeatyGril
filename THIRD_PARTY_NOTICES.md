# 第三方资料与许可边界

代码由 OpenAI + Codex 全程编写，站长仅参与调试和测试。项目代码、脚本及文档按根目录 MIT License 提供。署名 Dayu 不表示第三方代码、样本与 SDK 的版权转移。

- Apple FxPlug / PluginManager SDK 和随正式插件分发的运行框架属于 Apple；受 Apple 相应 SDK 与再分发条款约束，源码仓库不包含这些框架。编译需自行安装 Xcode 与 FxPlug SDK。macOS Vision、AppKit、CoreImage 属于系统组件。
- `Templates/大鱼人像美化/Drop Zone.tiff` 是 Motion 工程的标准占位资源，随模板保留；不将其声明为 Dayu 原创作品或另行授予 MIT 权利。
- `tests/fixtures/astronaut.png` 来源于 NASA 的 Eileen Collins 图像，经 scikit-image 样本分发，详见同目录 ATTRIBUTION.txt。相关分析预览由该公开样本生成。
- `docs/analysis` 中的对照分析、符号和反汇编摘录是互操作研究材料，不包括目标商业 APP、模型或 metallib。MIT 不为其原权利人的内容重新授权。本项目不声称与目标商业插件的模型或画面逐像素一致。
- `Assets/Artwork/portrait-cover.png`、APP 中 `LauncherInfo.png` 及两张模板缩略图由内置图像生成工具创作。人物为虚构成年古风人物，封面是宣传插画，不是真实滤镜前后效果对比；生成说明和提示词见 `docs/design`。未使用目标插件的宣传人像。
- 不包含用户测试素材、用户工程、真实人脸坐标数据、签名私钥、公证密码或账号令牌。签名证书与公证凭据不属于源码恢复范围。

免费发布版本无需激活码、付费注册或联网授权。安装时执行系统插件注册；主 APP 打开后显示说明并在三秒后退出，宿主内的 FxPlug 服务独立运行。
