# 恢复说明

- 私有远程：`https://dayu.media/git/dayu/paintfcp-fxplug.git`
- 本地项目根：`/Users/dayu/Documents/PaintFCP`
- 工作分支：`main`
- 修改前版本标签：`baseline-20261021`，完整 SHA：`1746f38398588e2367abb37a5c2b31cb64042429`
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

## 首次远端恢复核验（2026-10-21）

已在本任务创建的独立临时目录从远端克隆 `baseline-20261021`，核验 HEAD 为 `1746f38398588e2367abb37a5c2b31cb64042429`，并与本地该提交的 23 个受跟踪文件逐字节比对一致；恢复目录可通过 `xcodebuild -list` 读取两个 target / scheme。远端 `main` 与标签解引用 SHA 均回读一致。临时恢复目录已清理。

初始模板存在行尾空白，修改前基线保留原样。本次核验未执行初始 APP 编译、签名、公证、安装或宿主加载；这些将由最终实现阶段单独验证。
