# GitHub 发布目标

目标：https://github.com/FAMEDaYu/FCP-BeatyGril

本地已添加 `github` 远端，保留 `origin` 指向大鱼仓库，`main` 继续跟随 `origin/main`。首次检查时 GitHub 为公开空仓库。源码、既有历史和全部版本标签将通过 Git 正常推送；1.2.0 正式安装包另上传到 GitHub Release。不开启镜像强推，不覆盖 GitHub 端已有提交或标签。

当前状态：等待具有目标仓库写权限的 GitHub 登录授权。尚未声称 GitHub 备份完成，也不会提前把文章的源码入口切换到空仓库。原大鱼站备份继续可用。

登录完成后，以 GitHub 账号和目标仓库权限回读为准。推送后检查远端所有分支 / 标签 SHA，并独立匿名克隆、核对源码与正式 PKG 哈希；再更新文章链接。

正式 PKG：`releases/1.2.0/大鱼人像美化-1.2.0.pkg`，SHA-256 `5bd77c28b3a7e54f3d4060be1f16bcb145d9bc4d6b9cfb9eb137c01130440243`。不重新编译、修改或签名安装包。

源代码编写署名：代码由 OpenAI + Codex 全程编写，站长仅参与调试和测试。
