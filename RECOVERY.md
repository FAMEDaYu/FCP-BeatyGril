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
git switch --detach v1.0.6
```

需要继续编辑时，基于该提交创建新分支。安装 Xcode 与 Apple FxPlug 4 SDK；盘点版本和构建入口见 README.md。SDK/framework 为 Apple 外部开发依赖，应重新安装匹配版本。证书、私钥和公证凭据需从独立加密备份恢复或重新申请；Git 不包含它们。

恢复承诺仅覆盖已成功推送且核验的提交与仓库内资源。大鱼服务当前只有手动服务端备份，不能据此承诺本机与服务器同时丢失后的恢复。

## 首次远端恢复核验（2026-10-21）

已在本任务创建的独立临时目录从远端克隆 `baseline-20261021`，核验 HEAD 为 `1746f38398588e2367abb37a5c2b31cb64042429`，并与本地该提交的 23 个受跟踪文件逐字节比对一致；恢复目录可通过 `xcodebuild -list` 读取两个 target / scheme。远端 `main` 与标签解引用 SHA 均回读一致。临时恢复目录已清理。

初始模板存在行尾空白，修改前基线保留原样。本次核验未执行初始 APP 编译、签名、公证、安装或宿主加载；这些将由最终实现阶段单独验证。

## 1.0.4 恢复入口

最终交付标签为 `v1.0.4`，工作分支为 `main`；本次实际编译和独立恢复测试的代码节点为完整 SHA `e03e460a9b3e5ad489aad24095485ba10ceb987d`。最终标签还包含验证文档。需要精确恢复已测试源码时可执行 `git switch --detach e03e460a9b3e5ad489aad24095485ba10ceb987d`。两者都保留初始模板及全部中间提交。

依赖：Xcode27.1、FxPlug SDK4.3.4、PluginManager1.7.4，系统最低macOS13；Metal与Vision由系统提供。SDK头文件/链接存根安装到 `/Library/Developer/SDKs/FxPlug.sdk/Library/Frameworks`，可执行运行框架在 `/Library/Developer/Frameworks`；不要把SDK链接存根当运行框架嵌入APP。两者属于需重新安装的Apple外部依赖，仓库不保存证书/私钥或登录凭据。

测试与通用Release构建命令见README。关闭Motion和FCP后，执行 `python3 scripts/deliver.py` 完成正式签名、公证、粘附、唯一目录安装与验收后的副本清理；签名团队为B3W25FX5H5，公证使用登录钥匙串profile `codex-dayu-notary-B3W25FX5H5`。新机器需要自行恢复凭据或重新签发，不要把凭据加入Git。

FCP模板从 `Templates/大鱼人像美化/` 恢复，将 `.moef` 和 `Drop Zone.tiff` 一起放入 `~/Movies/Motion Templates.localized/Effects.localized/大鱼/大鱼人像美化/`；只放 `.moef` 会缺少标准效果源输入资源。正式APP仅安装在 `/Library/Plug-Ins/FxPlug/beatygril.app`，不是从工作树或构建目录运行。没有LFS或子模块，必要工程资源、NASA测试人像及配套模板资源均在Git中。

用户用于宿主验收的外置卷视频及build内的验收工程/截图属于测试素材与可重建产物，不属于产品构建依赖，也没有远程上传。原MSE18V2 APP与原版MS模板仅为只读参考，不作为运行依赖。远端恢复记录及实际宿主测试范围见 `docs/验证记录.md`。

## 瘦脸与侧脸问题的分析节点

`v1.0.4`之后的分析提交包含`docs/analysis/脸型变形与转脸分析.md`、`slim-pose-report.json`、REA证据包及独立Vision离线检测工具`scripts/inspect-face-geometry.m`。产品源码与安装版没有因该分析改变；已查明的问题仍存在于1.0.4。复现检测工具的依赖与命令见分析文档，用户视频、完整人脸坐标和帧图保留本地，不是产品恢复依赖。

## 1.0.5 当前恢复入口

当前发布标签为 `v1.0.5`，APP版本1.0.5、build7。签名构建的完整源码SHA为 `abe97ed0cbd5a2b5ffda6ebdb486d3bff9170964`；最终标签还包含交付脚本恢复修正及验证记录，产品源码与该SHA一致。该节点已从独立远端克隆恢复，69文件及9项必要资源完整、389项核心测试通过。主工作区另通过604项完整回归及同一用户视频11帧的264项瘦脸ASan场景。

从最终标签恢复后，关闭Motion/FCP，运行 `python3 scripts/deliver.py --wait-for-hosts --user-tests` 可完成签名公证安装、只读宿主退出等待、静态发现及副本清理；它不会操作宿主界面。若上次因非产品错误在Accepted且stapled后停止，可加 `--resume-prepared`，脚本必须重新核对签名CDHash、版本、票据及产品源码未变才会继续。缺少原staging或回执时应完整重新构建，不能伪造回执。

1.0.5瘦脸需要完整76点；旧离线记录缺该字段时保留其余功能并跳过瘦脸。关闭使用跟踪数据可使用当前帧自动76点，或重新分析生成新记录。没有引入原版metallib或CoreML模型，运行只依赖本产品及Apple系统框架。最终安装、配套模板和扫描范围见验证记录。

## 1.0.6 恢复入口

本次签名构建源码SHA为`ad54726b17fabd11f46bc6121e664eac38960a23`，APP版本1.0.6、build8；最终发布标签为`v1.0.6`。恢复该SHA可重建相同产品源码，最终标签另包含交付文档与回执。Release恢复仍用上节同一构建/公证命令、固定Bundle ID和正式安装路径；用户自测模式不会操作Motion/FCP界面。

新增下巴三pin与图像适配轴修复；新分析档案使用`hostCoordinateSpace=iosurface-ci-y-up-v1`。旧未标记档案保留原字符串但回退实时跟随，重新分析后才能用于离线重放，不能直接补字段伪装成新档案。七类剩余脸型项及组合顺序仍有近似边界。

`ad54726b17fabd11f46bc6121e664eac38960a23`已独立从上述远程克隆，87文件的byte/blob/mode与14项资源一致，strict/full fsck和559项核心测试通过，无LFS、子模块或APP产物。临时恢复目录已清理，完整报告见`docs/verification/v1.0.6/recovery-ad54726.json`。

1.0.6已完成正式签名、公证（Accepted ab0271c8-0c4b-4b10-9474-cebe9b55385b）、票据粘附、唯一正式目录安装和配套模板同步；临时APP/旧备份APP/公证ZIP已清理。完整回执及有界副本扫描见`docs/verification/v1.0.6/installed-verification.json`。未操作Motion/FCP界面，最终视觉验收保留为用户自测。
