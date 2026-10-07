# 课序 · 免费账号试用与 IPA 安装

`CourseFlow-Trial-SideStore-unsigned.ipa` 是真实 iPhone / iPad 的 arm64 安装包，最低 iOS 26，可在仓库的 Releases 页面下载，或按下文「重新打包」自行生成。它还没有设备签名，**不能直接在 iPhone 文件 App 中点开安装**。没有付费开发者会员也能在自己的设备试用：使用普通 Apple 账号在 Xcode 选择 Personal Team，让 Xcode 为自己的手机签名并安装。

Apple 当前说明：Personal Team 的描述文件签发后 7 天到期，届时需要重新构建、安装；每台设备最多安装 3 个这类 App。签名只负责允许安装，不会给 App 增加 iCloud 等完整开发者能力。[Apple 账号与 Personal Team 说明](https://developer.apple.com/help/account/basics/about-your-developer-account)

## 推荐：使用现成工程装到自己的 iPhone

1. 用本机 Xcode 27 打开 `CourseFlow.xcodeproj`，在顶部选择 **CourseFlowTrial** scheme。
2. 打开 Xcode → Settings → Apple Accounts，登录自己的 Apple 账号；无需购买开发者会员。账号登录、密码和双重认证在 Xcode 的原生登录界面完成。[Apple 添加账号说明](https://help.apple.com/xcode/mac/current/en.lproj/devaf282080a.html)
3. 在工程的 **CourseFlowTrial target → Signing & Capabilities** 中保持 Automatically manage signing，Team 选择自己的 **Personal Team**。如果 Bundle Identifier 被占用，改成自己唯一的名称，例如 `com.yourname.courseflow.trial`。
4. 用数据线连接 iPhone，解锁并信任这台 Mac。顶部运行目标选择这台 iPhone。设备系统必须是 iOS 26 或更新版本。
5. 按 Xcode 提示启用 iPhone「设置 → 隐私与安全性 → 开发者模式」，并完成设备要求的重启和确认。[Apple 开发者模式说明](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device)
6. 点击 Run（▶）或按 ⌘R。Xcode 会生成签名、安装并启动课序；如果手机提示信任开发者，按系统提示在设置中信任自己的账号。

续期时使用相同的 Team 和 Bundle Identifier 再运行即可。**不要先删除 App**；删除会删除本机课表。建议先在设置导出课序备份。试用 target 和正式 target 的 Bundle Identifier 不同，之后迁移正式版时使用文件备份恢复课表。

这里不需要导出“已签名分发 IPA”：Personal Team 的直接构建运行即可完成个人设备试用。普通未签名 IPA 不能通过 AirDrop、Safari 链接或「文件」App 变成可安装包。

## 已有 IPA 重签工具时

该 IPA 使用标准的 `Payload/CourseFlowTrial.app` 目录，未包含 Widgets、CloudKit、App Group、远程推送能力或描述文件，可供你已经使用的个人签名工具导入。需要由工具使用你自己的账号、证书与设备描述文件签名后再安装；签名工具的兼容性和免费账号限制以其当前说明为准。本交付没有配置、验证或附带第三方签名服务。

## 试用版功能

| 可试用 | 本地课表和精细编辑；图片、PDF、Excel、文字导入及纠错；作息设置；实时课程状态；本地通知；系统日历；文件备份；课表图片和 PDF 导出；自配云端识别 |
| --- | --- |
| 本包停用 | iCloud 同步、桌面和锁屏小组件、实况活动、远程推送 |
| 数据位置 | 本机 App 容器；API Key 在本机 Keychain |
| 外部验证 | 真实手机首次授权、锁屏通知和系统日历权限仍需安装后检查 |

完整 `CourseFlow` scheme 保留原有能力；本试用 target 共享相同业务代码和图标，只隔离需要额外签名配置的系统扩展。不要为了给试用包签名而删除完整 target 的能力配置。

## 重新打包

在工程根目录执行：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  bash Scripts/package_ipa.sh
```

默认输出目录 `dist/`：

- `CourseFlow-Trial-SideStore-unsigned.ipa`：未签名设备包。
- `CourseFlow-Trial-SideStore-unsigned.manifest.json`：版本、平台、签名状态、禁用能力和 SHA-256。
- `CourseFlow-Trial-SideStore-unsigned.sha256`：安装包校验值。
- `trial-build.log`：实际构建日志。
- `INSTALL-IPA.md`：本说明副本。

脚本使用独立 `/tmp/courseflow-trial-device-build` 构建目录，检查 arm64/iPhoneOS、iOS 26、试用标记、禁用能力、扩展缺失及 ZIP 完整性。`COURSEFLOW_BUILD_DIR`、`COURSEFLOW_OUTPUT_DIR` 可以覆盖这两个输出位置。脚本不会登录账号、生成证书或修改手机。

脚本保留现有 Xcode 工程中的 Team 和 Bundle Identifier 设置，仅在工程缺失时生成工程。手动运行 `Scripts/generate_project.py` 会重建工程并覆盖在 Xcode 中改过的设置。日常安装和 7 天续期直接在 Xcode 按 Run 即可，不需要运行打包脚本。


当前时间提示、官方假期及学校调休确认，见 [详细说明](OFFICIAL-HOLIDAYS.md)。
