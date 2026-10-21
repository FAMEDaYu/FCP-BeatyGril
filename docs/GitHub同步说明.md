# GitHub 同步与恢复

公开源码：https://github.com/FAMEDaYu/FCP-BeatyGril

正式安装包：https://github.com/FAMEDaYu/FCP-BeatyGril/releases/tag/v1.2.0

本地 `github` 远端指向上述 GitHub 仓库，`origin` 继续指向大鱼仓库，`main` 仍跟随 `origin/main`。当前项目的完整提交历史、main 和七个版本标签已推送，两端引用与本地一致；未改写历史或覆盖标签。后续更新需要分别推送到 origin 和 github，不会自动定时同步。

## 已验证的 GitHub 恢复节点

匿名恢复提交：`356683b41af702d6c0143ad7fa5f540d752d6e14`。在关闭凭据助手和交互登录的独立临时目录中成功克隆 GitHub，197 个受跟踪文件逐字节一致、七个标签引用一致，strict/full fsck 通过。正式 PKG 的源码内副本与 GitHub Release 匿名下载副本 SHA-256 相同，下载副本的 Installer 签名与公证票据通过。后续 main 提交补充文章和验证记录，产品源码与该恢复节点一致。

安装包：`Dayu-Portrait-1.2.0.pkg`，5,011,005 bytes，SHA-256 `5bd77c28b3a7e54f3d4060be1f16bcb145d9bc4d6b9cfb9eb137c01130440243`。Release 标签 `v1.2.0` 仍指向 `3c7261c3a861b9f4704cfb36055d7b500c239dab`，没有重新编译或改动正式安装包。

```sh
git clone https://github.com/FAMEDaYu/FCP-BeatyGril.git
cd FCP-BeatyGril
git switch --detach 356683b41af702d6c0143ad7fa5f540d752d6e14
```

本项目没有 LFS 或子模块。编译仍需自行安装 Xcode 和 Apple FxPlug SDK；签名私钥与公证凭据不在 Git 内。GitHub 公共克隆无需登录；大鱼备份仍受站点登录和会员网关限制。两边都只承诺已经提交、推送并核验的节点。

源代码编写署名：代码由 OpenAI + Codex 全程编写，站长仅参与调试和测试。
