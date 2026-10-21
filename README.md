# PaintFCP FxPlug4

独立 FxPlug4 滤镜程序源码工程。修改前的 `beatygril` 是 Apple Tileable Remote Brightness 模板；在此基础上实现新的滤镜。第三方参考 APP、二进制和资源不进入仓库。

## 工程

- `beatygril/beatygril.xcodeproj`：Xcode 工程，`Wrapper Application` 与 `XPC Service` 两个 target。
- `beatygril/beatygril/Plugin`：Objective-C `FxTileableEffect` 实现、Metal GPU shader 和设备缓存。
- `beatygril/beatygril/Wrapper Application`：插件外层 APP 和沙盒 entitlement。
- 原始参数：Brightness，默认 1.0，参数范围 0–100，滑块范围 0–10；RGB 乘亮度、Alpha 保持。

## 本机依赖与构建入口

盘点环境：Xcode 27.1（27A9275），FxPlug.framework 4.3.4、PluginManager.framework 1.7.4；附加 SDK 为 `/Library/Developer/SDKs/FxPlug.sdk`。SDK 内含开发 headers，运行 framework 位于 `/Library/Developer/Frameworks`。项目初始最低部署目标为 macOS 27.2。

```sh
xcodebuild -list -project beatygril/beatygril.xcodeproj
xcodebuild -project beatygril/beatygril.xcodeproj \
  -scheme 'Wrapper Application' -configuration Release \
  -derivedDataPath /tmp/paintfcp-build \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY='Developer ID Application: zhong luo (B3W25FX5H5)' \
  DEVELOPMENT_TEAM=B3W25FX5H5 build
```

初始工程复制并签名 FxPlug 与 PluginManager 两个 framework；正式交付必须依次完成 Release 构建、内到外签名、Apple 公证 Accepted、票据粘附与验证、唯一正式路径安装及宿主发现验证。初始基线仅核验工程可读取和依赖，不代表已完成构建或交付。

参考 [RECOVERY.md](RECOVERY.md) 恢复源码与依赖。签名证书、私钥和公证凭据均由本机钥匙串管理，不随源码保存。
