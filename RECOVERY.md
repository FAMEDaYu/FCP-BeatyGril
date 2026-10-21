# 恢复说明

- 私有远程：`https://dayu.media/git/dayu/paintfcp-fxplug.git`
- 本地项目根：`/Users/dayu/Documents/PaintFCP`
- 工作分支：`main`
- 修改前版本标签：`baseline-20261021`（完整 SHA 在后续恢复核验记录补充）
- 无 Git LFS 或子模块；源码及必要 Xcode 工程资源均入库。
- `/Applications/MSE18V2.app` 是只读参考目标，不属于本项目资源，不随仓库保存。

在新机器登录大鱼站并生成自己的 Git 令牌后，以安全 credential helper 登录，然后：

```sh
git clone https://dayu.media/git/dayu/paintfcp-fxplug.git
cd paintfcp-fxplug
git switch --detach baseline-20261021
```

需要继续编辑时，基于该提交创建新分支。安装 Xcode 与 Apple FxPlug 4 SDK；盘点版本和构建入口见 README.md。SDK/framework 为 Apple 外部开发依赖，应重新安装匹配版本。证书、私钥和公证凭据需从独立加密备份恢复或重新申请；Git 不包含它们。

恢复承诺仅覆盖已成功推送且核验的提交与仓库内资源。大鱼服务当前只有手动服务端备份，不能据此承诺本机与服务器同时丢失后的恢复。
