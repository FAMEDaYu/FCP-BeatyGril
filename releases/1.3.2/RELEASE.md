# FCP-BeautyGirl · 大鱼人像美化 1.3.2（17）

统一工程、APP、插件服务、源码类名和应用标识的拼写。主 Bundle ID 为 `com.dayu.fcpbeautygirl`，插件 ID 为 `com.dayu.fcpbeautygirl.fxplug`，唯一正式安装路径为 `/Library/Plug-Ins/FxPlug/FCP-BeautyGirl.app`。

安装器核对旧版的 Bundle ID、签名团队和滤镜 UUID 后迁移旧 APP；失败时恢复旧版，避免新旧服务并存。滤镜 UUID、参数编号和面板归档保留，渲染逻辑沿用 1.3.1。1901 项自动回归、8 项 APP 迁移测试、8 项安装器身份迁移测试，以及模板初装、更新与失败回滚隔离检查通过。更名后的旧工程重开与原生画面仍需用户实测。

- 文章：https://dayu.media/15593/
- GitHub：https://github.com/dayumeida/FCP-BeautyGirl
- 大鱼备份：https://dayu.media/git/dayu/paintfcp-fxplug
- 发布标签：v1.3.2
- 正式 APP 签名源码：767bba8ac11e9bf9268a1e02d1a06d3c120c46aa
- APP 公证：Accepted 559eedf0-048f-4d0e-b013-6a187695f2da
- PKG 公证：Accepted 4a831775-2317-4372-a4cc-102415657ea3
- PKG：FCP-BeautyGirl-1.3.2.pkg，4,889,706 bytes
- SHA-256：20a88dacf68cc8812f5af86cfe94c1c0614414a68a019eaeac7ca9d078165ae1

本机 PKG 工坊 CLI 生成基础包，加入本产品的旧身份迁移与回滚段后，对最终包重新签名、公证和粘附票据。包含用户指定的「大鱼磨皮瘦脸」分类：大鱼人像美化.moef、Drop Zone.tiff、large.png 和 small.png。有效载荷与正式 APP、四个模板文件一致；恢复两张缩略图的锁定。签名、公证票据、Gatekeeper 和隔离安装脚本核验通过，未实际运行本 PKG 安装器；本机 APP 已通过正式交付流程安装。

安装前保存并退出 Final Cut Pro 和 Motion。Final Cut Pro 在「效果 → 大鱼磨皮瘦脸 → 大鱼人像美化」中使用。免费开源，无需激活码。代码由 OpenAI + Codex 全程编写，站长仅参与调试和测试。Apple SDK 及相关资源遵循各自许可。
