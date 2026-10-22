# Z30 Recipes · Z30 配方

一款为 Nikon Z30 制作的 iOS 配方管理工具：把配方保存在 iPhone，通过相机 Wi-Fi 载入 C1–C9 自定义优化校准槽位。

当前版本 **1.0.4**。这是独立开源项目，与 Nikon 无隶属关系。

## 功能

- 从 iPhone「文件」一次多选导入 NCP／NP3，按内容去重，显示成功、重复、失败数量。
- 手机配方库：选择配方、删除本机副本；删除前显示名称供确认。
- 单个槽位载入并应用，或一次配置多个 C1–C9 槽位。
- 使用 PTP/IP 写入，随后读回核对名称、参数和完整曲线，再应用目标槽位。
- App 前台保持连接；进入后台主动断开。
- 保留导入的原始文件，不自动创建相机配方备份。

## 在 iPhone 上运行

1. 在 Mac 上安装带 iOS SDK 的 Xcode，打开 `Z30Lab.xcodeproj`。
2. 在 **Signing & Capabilities** 选择自己的 Team，并把 Bundle Identifier 改成自己的唯一标识。
3. 连接 iPhone，在 Xcode 中选择设备并运行。按系统要求启用开发者模式、信任开发者。
4. 在 Z30 上选择 P／S／A／M 档，进入「连接至智能设备 → Wi-Fi」，让 iPhone 加入相机网络。
5. 打开 App，点击「批量导入」。文件选择器中可多选配方，选完点击「打开」。
6. 选择配方和 C 槽位，点击「一键替换并应用」；批量写入使用「批量配置 C1–C9」。

写入会替换选中槽位原有配方。相机上的配方与手机配方库是两份数据，删除手机副本不会删除相机配方。

## 格式与验证范围

| 类型 | 当前情况 |
| --- | --- |
| NCP `0100`：标准、自然、鲜艳、单色、人像、风景 | 已实现无线编码，可尝试载入；没有“仅自然基底”白名单 |
| 普通 NP3：上述传统基础风格 | 已实现参数及曲线编码 |
| 578 字节自定义曲线 | 保留完整曲线块，包括控制点和 257 项 LUT |
| Flexible Color `0310` / 基底 `0020` | 识别格式；尚未实现其完整无线编码或无损降级，不能承诺完整还原分色及分区调色 |
| 自动参数、彩色单色调色、未实测风格 | 已有试验编码，仍需逐项实机验证 |

实机开发使用 Z30 固件 C 1.20。标准、自然及单色配方已在开发设备完成写入和读回验证；其中自然配方还通过相机另存到 SD 卡的文件核对。其他机型尚未验证，连接器会核对机型。

“相机接受写入”“读回数据一致”“实拍外观一致”是三个不同结果。本项目主要核对前两项；不把格式转换成功等同于 Flexible Color 外观还原。

## 构建与测试

核心模块使用 Swift Package，网络测试在本机建立模拟 PTP/IP 相机，不需要真实相机。

```sh
swift test
```

测试数据全部由脚本生成，不包含真实相机序列号、手机诊断、相机备份或第三方滤镜包：

```sh
python3 tools/generate_test_fixtures.py
swift test
```

无需签名的 iOS 编译检查：

```sh
xcodebuild -project Z30Lab.xcodeproj -scheme Z30Lab \
  -configuration Release -destination 'generic/platform=iOS' \
  CODE_SIGNING_ALLOWED=NO build
```

## 代码结构

- `Sources/App/`：SwiftUI 配方库、批量文件导入、删除和 C1–C9 配置界面。
- `Sources/Core/PTPCodec.swift`：文件解析、配方编码、批量文件导入和协议数据结构。
- `Sources/Core/PTPIPProbe.swift`：相机会话、心跳、串行事务、写入及读回。
- `Tests/CoreTests/`：文件、曲线、批量导入、模拟网络和异常处理测试。
- [协议笔记](docs/PROTOCOL.md)：已观测的数据布局与仍待验证的部分。

## English

An independent iOS recipe manager for the Nikon Z30. Import multiple NCP/ordinary NP3 files into a local library, delete local copies, and load recipes into custom Picture Control slots C1–C9 over Wi-Fi PTP/IP. Complete curve data is retained and read back after writes. Flexible Color effect conversion is **not** implemented. Open the Xcode project, select your own signing team and bundle identifier, and run on your iPhone. Run `swift test` for the core and mock-camera tests.

## 许可证与参考

代码使用 [MIT License](LICENSE)。第三方研究参考见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。仓库不提供或重新授权第三方作者的摄影配方。
