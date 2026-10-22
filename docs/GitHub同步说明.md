# GitHub 同步与恢复

公开源码：https://github.com/FAMEDaYu/FCP-BeautyGirl

正式安装包：https://github.com/FAMEDaYu/FCP-BeautyGirl/releases/tag/v1.3.1

本地 `github` 远端指向上述 GitHub 仓库，`origin` 继续指向大鱼仓库，`main` 仍跟随 `origin/main`。当前项目的完整提交历史、main 和全部现有版本标签已推送，两端引用与本地一致；未改写历史或覆盖标签。后续更新需要分别推送到 origin 和 github，不会自动定时同步。

## 已验证的 GitHub 恢复节点

匿名恢复提交：`356683b41af702d6c0143ad7fa5f540d752d6e14`。在关闭凭据助手和交互登录的独立临时目录中成功克隆 GitHub，197 个受跟踪文件逐字节一致、七个标签引用一致，strict/full fsck 通过。正式 PKG 的源码内副本与 GitHub Release 匿名下载副本 SHA-256 相同，下载副本的 Installer 签名与公证票据通过。后续 main 提交补充文章和验证记录，产品源码与该恢复节点一致。

安装包：`Dayu-Portrait-1.2.0.pkg`，5,011,005 bytes，SHA-256 `5bd77c28b3a7e54f3d4060be1f16bcb145d9bc4d6b9cfb9eb137c01130440243`。Release 标签 `v1.2.0` 仍指向 `3c7261c3a861b9f4704cfb36055d7b500c239dab`，没有重新编译或改动正式安装包。

```sh
git clone https://github.com/FAMEDaYu/FCP-BeautyGirl.git
cd FCP-BeautyGirl
git switch --detach 356683b41af702d6c0143ad7fa5f540d752d6e14
```

本项目没有 LFS 或子模块。编译仍需自行安装 Xcode 和 Apple FxPlug SDK；签名私钥与公证凭据不在 Git 内。GitHub 公共克隆无需登录；大鱼备份仍受站点登录和会员网关限制。两边都只承诺已经提交、推送并核验的节点。

源代码编写署名：代码由 OpenAI + Codex 全程编写，站长仅参与调试和测试。


## 1.3.1 当前发行与恢复

main已快进纳入1.3.0磨皮参数和1.3.1的V脸下颌修复；origin和github的main及v1.3.1引用已回读核验。v1.3.1固定完整SHA为 `b35b4a5d1ca252d2f83c798613560a768274de3c`，签名APP源码为 `7fa3298e022946e77dfd8cfba1bb5ff2c2a6361f`。独立匿名GitHub克隆232文件字节与执行位一致、strict/full fsck和恢复PKG签名/票据通过。无LFS或子模块。后续main仅补充发布记录，不改写标签。

GitHub Release已提供 `Dayu-Portrait-1.3.1.pkg`（5,011,286 bytes，SHA256 `a6bb7262c9066e7abca8d1f21eaeaf1ba6a1d0d51b4859d39307aa7d7b0bc927`）和源码ZIP（9,682,532 bytes，SHA256 `7c335f54717a73e710ef484fc9f7b90864211c128a0f217bf170aa092333f228`）。两者匿名重新下载哈希一致，PKG签名和票据通过。源码快照基于上述v1.3.1节点，排除PKG本体而保留全部构建源码、模板、素材与验证文档。

大鱼站同名Release附件上传与名称/大小回读通过，下载入口仍受站点登录保护；未宣称API令牌可直接回读该浏览器附件入口。文章15593已就地更新，主包和源码链接的新文件哈希通过，免费规则、封面、作者、分类及未修改资源字段保持一致。正常URL和新请求的前台版本、安装/使用/故障说明及三项SEO均核验，未登录页面显示免费及登录获取入口；未下测试订单。详见verification/v1.3.1。


## 2026-10-22 仓库名称拼写更正

GitHub仓库从 `FAMEDaYu/FCP-BeatyGril` 更名为 `FAMEDaYu/FCP-BeautyGirl`，仓库ID `1428817365` 保持一致。更名前后全部分支/标签SHA、Release与附件ID/大小一致，未另建仓库或改写历史。本地github远端已改为 `https://github.com/FAMEDaYu/FCP-BeautyGirl.git`，origin和main上游仍为原大鱼仓库。现有发布标签、已公证APP/PKG及源码快照保留原始字节，旧快照里的旧链接由GitHub重定向到新地址；当前文档、文章和Release说明使用新地址。插件APP产品名、Bundle ID和安装路径沿用原配置。更名核验见verification/github/rename-20261022.json。
