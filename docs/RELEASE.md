# 课序开发验证与发布准备

更新日期：2026-10-02。工程名 `CourseFlow`，App 名「课序」，版本配置为 1.0 / 3，主 Bundle ID 为 `com.courseflow.app`。

## 节日分组与批量确认增量验收（2026-10-02）

- 首页按公告年份与节日名称分组。从完整分组最早日期前 7 天开始提示，2026 年国庆 9 月 13 日起即包含 9 月 20 日补班、10 月 1–7 日放假和 10 月 10 日补班。确认假期后，未处理的补班仍提示；全部当天及未来日期处理完后隐藏，历史日期仍可修改。
- 新确认页默认选中本学期内未确认的假期日期，整段放假一次设置。允许取消单日、按日期编辑、补班保留待确定；确认栏显示日期范围、天数及已过日期说明。设置中的日期也按节日归组。
- 一次批量保存、一次撤销；继续复用逐日决定和整日换课，备份维持 v2。批量拒绝已确认或手动调整的日期，校验失败不部分写入。同步资料更新时会刷新课程并清除旧撤销记录，避免旧撤销覆盖新安排。已有单次新增／移入课程及系统日历手改保护保持有效。
- **85 项核心测试、9 个 suite 全部通过**（新增 9 项）。最终主 App 的 14 项存储、批量、通知、日历及小组件集成检查无失败、无跳过；包含真实待发送通知和真实日历事件的移除／替换检查。
- 10 项独立时间／调休 UI 用例均有通过记录，包含 5 项时间／导出回归和 5 项节日分组／批量场景。这是分轮修复后的汇总：初始联合 UI 检查有失败，不能将初始联合结果描述为全通过。最终批量操作专项 3 项全部通过；同步保护修正后，14 项 App 检查与 1 项七天确认 UI 联合通过。
- 小屏 iPhone 17e、iPad（A16）的实际批量提交、排除单日、深色大字号检查通过。界面截图见 [整组首页提示](screenshots/holiday-batch/home.png)、[批量确认](screenshots/holiday-batch/group-confirmation.png)、[取消单日](screenshots/holiday-batch/excluded-date.png)、[假期确认后补班仍待定](screenshots/holiday-batch/makeup-pending.png)、[iPad 系统大字号](screenshots/holiday-batch/ipad-system-large-dark.png)。另在模拟器系统中设为辅助功能大字号，重测确认页通过，随后已恢复模拟器字体设置。
- 主 App / Widgets 的签名模拟器构建、试用版 arm64 Release 设备构建通过。最新包 `dist/CourseFlow-Trial-SideStore-unsigned.ipa` 为 1.0（3），桌面名称 `CourseFlow`，校验值与文件清单同目录保存；ZIP、版本、arm64、iOS 26 最低版本及无签名状态已验证。仍需 SideStore 签名，未在真机安装此版本。

验证日志见 [verification/2026-10-02](verification/2026-10-02)，使用说明见 [OFFICIAL-HOLIDAYS.md](OFFICIAL-HOLIDAYS.md)。本次未修改官方公告解析与联网抓取流程；沿用上次联网核验与已核验的 2026 年内置数据。

## 当前时间与官方调休增量验收（2026-10-01）

- 当前时间线、日程中的「现在」位置、课程状态与昼夜图标已实现。按学校时区、分钟更新，返回前台刷新；导出图像和 PDF 使用静态课表。
- 内置 2026 年官方放假 / 补班资料。已在模拟器实际访问中国政府网公告并通过官方站内检索发现 2026 年公告，两项联网检查通过；解析规则遇到模板变化会保留有效缓存，不推算未知年份。
- 调休提示提前 7 天，不弹窗。待确认保留原课程与提醒；确认后通过统一引擎刷新课程、日历、通知及共享小组件资料。单双周按明确参照教学周计算。放假停课保留明确新增、移入当天的单次课程。
- v2 备份支持新决定与提示设置，并向后读取 v1。存储 / 撤销集成检查修复了旧逻辑中数组存储顺序导致的误判，仍保留对同步新更改的保护。
- **76 项核心测试、9 个 suite 全部通过**。含 11 项新增调休测试，使用保存的官方公告验证日期、星期、天数、来源、单双周、单次补课、提示窗口、旧备份和确认幂等性。
- App 的导入、AI 导入、持久化、联网核验与系统回归合计 30 项联合运行完成；未签名宿主中 App Group 用例跳过。随后签名模拟器专项重新执行该 App Group 用例与新增的 2 项调休通知 / 日历用例，3 项全部通过，无跳过。因此 32 项独立 App 用例均有通过记录，不能把未签名联合运行描述为零跳过。
- 新 UI 用例覆盖时间线 / 列表、保留待定及确认、夜间空日程、深色大字号、图片及 PDF 分享；另执行原通知授权 UI。小屏 iPhone 17e（iOS 27）通过，iPad（A16）上时间视图与大字号 UI 通过。截图见 [周课表](screenshots/time-holiday/grid.png)、[日程](screenshots/time-holiday/agenda.png)、[大字号深色](screenshots/time-holiday/large-dark.png)、[调休确认](screenshots/time-holiday/confirmation.png)、[iPad](screenshots/time-holiday/ipad-grid.png)。
- 最新源码的主 App / Widgets 模拟器构建以及试用版 arm64 Release 设备构建通过。新包 `dist/CourseFlow-Trial-SideStore-unsigned.ipa` 为 1.0（2）、英文桌面名称 CourseFlow；ZIP、SHA-256、架构与无签名状态均经验证。仍需 SideStore 使用自己的账号签名，尚未在真机安装新版。

此次可保留的日志在 [verification/2026-10-01](verification/2026-10-01)，新增功能使用说明见 [OFFICIAL-HOLIDAYS.md](OFFICIAL-HOLIDAYS.md)。后续年度未发布、政府页面不可访问或解析模板变化时，界面会提示资料不可用，保留既有确认决定。

iOS 26 真机运行、跨设备 CloudKit 同步、Instruments 性能及 App Store 发布仍沿用下述未完成验收边界，不因这次模拟器检查而视为通过。

## AI 文本导入增量验收（2026-09-11）

- 核心包 65 项测试、8 个 suite 全部通过，含新增的 16 项 AI JSON 测试以及课表/作息 JSON 示例；日志 `/tmp/coursekit-ai-import.log`。
- AI 导入 7 项及原导入 9 项 App 集成测试全部通过，验证解析只写草稿、无效数据保留原文、旧草稿升级兼容、恢复、用途隔离和正式保存去重；证据为 `/tmp/courseflow-ai-acceptance.log` 的 `CourseFlowTests.xctest` suite。该次联合运行的 UI 用例曾因滚动越过目标字段失败，不应将整份联合日志视为通过。
- 修正测试滚动方式并优化编辑页的键盘收起后，AI UI 流程重新通过；日志 `/tmp/courseflow-ai-ui-final.log`、结果包 `/tmp/courseflow-ai-ui-final.xcresult`。实际完成 JSON 输入、逐字段核对、修改课程名称与地点、保存到正式课表及打开课程详情；结束时间 `24:00` 可在核对页保留并保存。
- 在 iOS 27 小屏模拟器检查了 [AI 导入界面](screenshots/ai-import-iphone.png)，实际点击复制按钮后回读剪贴板，确认提示词使用示例学期的 18 周，而非独立文件的默认 20 周。
- 正式 App / Widgets 模拟器构建、试用版 iPhoneOS Release 构建通过。新版未签名 IPA 见 `dist/CourseFlow-Trial-unsigned.ipa`，最终构建日志为 `dist/trial-build.log`，SHA-256 已回读验证；仍需个人签名才能装到真机。

本模式没有调用外部 AI 或上传测试图片；上述验证覆盖提示词导出、JSON 接入与纠错保存，不代表任意外部 AI 的看图结果都正确。[使用说明与完整提示词](AI-IMPORT.md)。

## 当前验证记录

| 项目 | 本文件已掌握的证据 |
| --- | --- |
| 通知、日历、Activity、WidgetBridge、后台刷新 Swift 6 类型检查 | 已通过；Xcode-beta 的 iOS 27 SDK，部署目标 iOS 26 |
| 桌面、锁屏、灵动岛 Widget target 类型检查 | 已通过；同上 |
| 主 App + Widgets 完整模拟器构建 | 已通过；最新签名模拟器布局构建日志 `/tmp/courseflow-layout-final.log` 含 `BUILD SUCCEEDED` |
| Release / iPhoneOS SDK 构建 | 最新未签名构建已通过；日志 `/tmp/courseflow-release-verified.log`。真机安装与发行仍需签名 |
| 模拟器启动与真实界面 | 已检查 iPhone 17 Pro、iPad 与小屏 iPhone；深色对比和大字号纵向倒计时布局已复查。截图见 [深色](screenshots/iphone-dark.png)、[大字号](screenshots/iphone-large-type.png)、[iPad](screenshots/ipad.png)、[浅色](screenshots/iphone-light.png) |
| UI 用例 | 欢迎/示例课表、完整手动课程保存、通知授权、文本导入确认，共 4 个通过；证据为 `/tmp/courseflow-acceptance.log` 中的 UI suite |
| 最终 App 集成测试 | PDF 列表识别和 Swift 6 修正后重新执行，17 个用例全部通过，无跳过；含 9 个导入、4 个持久化、4 个系统集成用例，日志 `/tmp/courseflow-app-verified.log` |
| 第三轮系统专项测试 | 1 个通知授权 UI 用例、3 个系统用例全部通过，无跳过；日志 `/tmp/courseflow-system-tests-3.log` |
| 通知更新与 App Group 测试 | 已通过；验证通知改时/改名/改地点后的实际 pending 请求，以及共享容器快照写入、回读、恢复 |
| 核心包测试 | 现有 65 个测试、8 个 suite 全部通过；日志 `/tmp/coursekit-ai-import.log` |
| iOS 26 运行 | 部署目标为 iOS 26，已完成编译；运行验证使用 iOS 27 模拟器，尚未在 iOS 26 runtime 实际验收 |
| Instruments 性能测量 | xctrace 录制未正常完成，已终止；没有可作为通过证据的帧率、耗电或性能报告 |
| 真机通知送达、日历账户、CloudKit、实况活动 | 未完成签名真机验收 |
| TestFlight、App Store、隐私审核 | 未提交/未验证；没有公开上架完成记录 |

最终 App 集成测试日志 `/tmp/courseflow-app-verified.log` 为 `TEST SUCCEEDED`，17 个用例无失败、无跳过，已包含 PDF 列表识别修正。真实 EventKit 数据库验证了重复导出、单次修改、手改保护、移除以及「删 alarm / 修改提前量 / 外部移时间不算提醒覆盖」；通知验证了 65 个课次只排 60 条、重复排队无新增、改课后旧请求更新、仅清理本 App 自有请求；共享容器真实写入与回读也已通过。

UI 的 4 个通过结果取自 `/tmp/courseflow-acceptance.log` 内 `CourseFlowUITests.xctest` 测试包，包含 3 个主界面用例和 1 个导入用例。该次联合运行中的 App 测试曾因旧 PDF 识别问题失败，因此不能把这份联合日志标成 `TEST SUCCEEDED`；修正后的 App 通过证据来自上面的独立重跑日志。

## 可重复运行的检查

从仓库根目录运行核心测试，使用独立 scratch 目录：

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  swift test --scratch-path /tmp/coursekit-root-tests
```

测试覆盖学期教学周、单双周与跳周、作息映射、连堂课间、时间边界、例外与冲突、导入解析和备份等领域逻辑。它们不会弹出系统权限，也不证明任何外部账户已经同步。

构建模拟器 App（同时构建小组件）：

```sh
DEVELOPER_DIR=/Applications/Xcode-beta.app/Contents/Developer \
  xcodebuild -project CourseFlow.xcodeproj -scheme CourseFlow \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/courseflow-build CODE_SIGNING_ALLOWED=NO build
```

运行 UI 测试前，在 Xcode 选定实际存在的 iOS Simulator。Scheme 已包含宿主集成测试 `CourseFlowTests` 和 `CourseFlowUITests`；模拟器名称或 UUID 以本机安装内容为准，不应硬编码未安装设备。UI 测试使用 `--uitesting` 和 `--demo`，避免污染实际课表。系统集成测试只在模拟器执行：日历只创建名称带唯一测试标识的专属日历，结束后清理；App Group 测试会保存并恢复之前的快照。宿主测试停用 AppStore 的自动系统集成，避免与测试直接操作队列冲突。

## 系统集成验收

通知应在隔离测试设备上验证：首次允许、拒绝、系统设置中撤销权限；提前 0/10/30 分钟；超过 60 个待提醒课次；改课、停课与更改提前量后旧通知消失；日历覆盖与重复提醒开关；App 被挂起/结束、锁屏和断网时已排通知实际送达。界面展示的覆盖截止时间必须与系统 pending requests 一致。专注模式和系统通知设置仍可能改变呈现方式。

日历需要真实可写账户：首次导出、重复导出、不改课重新同步、仅修改某个课次、停课删除、批量写入失败重试、用户在日历中手改/删除、账户重同步导致标识变化、移除导出和多设备负责人切换。删除日历提醒、修改其提前量或把事件移到其他时间后，不得继续抑制原计划的 App 提醒。只能操作带本 App 标记的事件；不能用本地提交成功推定 iCloud 或其他账户已经上传完成。两台离线设备同时首次导出或接管不能视为已经通过防重验收。

实况活动和小组件需要已签名 App Group：小组件能读取真实课表；当前上课与下一节展示正确；预约活动在指定时间启动；连堂课间前台更新正确；后台内容过期后不继续展示错误的上课状态；用户关闭活动、系统并发额度耗尽和活动超时能正常降级。预约启动会产生系统提示；后台更新与精确移除不做常驻保证。

共享容器的写入与回读验证，只证明 App 写入的数据能够被小组件共用的读取代码正确解码。它不能代替把小组件实际添加到桌面/锁屏后，观察 Widget 进程的展示、系统刷新和深链行为；这些需要单独验收。Apple Intelligence 依赖设备、系统与模型可用性，BYOK 需要用户提供兼容服务和密钥，当前不假定这些外部条件已经满足。动画已使用原生交互与减弱动态效果选项，但尚未以真机 Instruments 给出帧率或耗电测量结果。

后台刷新必须在 App 启动时注册 `com.courseflow.app.refresh`，并在任务返回完成前等待通知刷新操作结束。系统唤醒时会再申请下一轮；退后台时也应申请。`earliestBeginDate` 是最早时间，不是调度承诺；不能拿它作为全学期通知的可靠前提。

## 签名、容器与发布

1. 用户或发布者填写自己的开发者 Team，注册主 App / Widget 标识，配置两个 target 的 `group.com.courseflow.app`，确认描述文件包含实际使用的能力。
2. `Config/Project.xcconfig` 提供 `COURSEFLOW_ICLOUD_ENABLED = NO` 默认值，并包含可选的 `Config/Local.xcconfig`；各 target 继承此配置。从 example 创建本机配置后仍先保持关闭；配置私有容器 `iCloud.com.courseflow.app` 后才在本机配置中设为 `YES`。`CloudSyncEnabled` 来自最终构建配置。不要提交 Team 私密材料、签名证书或 API Key。
3. 用同一 iCloud 账户的两台真机核对首次同步、离线编辑、删除、恢复和日历负责人。开发环境验证后，再按最终发布流程检查 CloudKit production schema 与描述文件。
4. 用真实测试图片、PDF、CSV 和 XLSX 做识别核对。Apple Intelligence 不可用时仍须能完成普通导入；BYOK 服务要确认用户主动上传、HTTPS、额度错误、取消、图片选项和密钥删除。
5. 在 App Store Connect 补充应用主体、隐私政策 URL、支持渠道、截图、年龄分级、隐私回答和必要的隐私清单；审核第三方依赖与当前发布要求。发布文案不能承诺任意模板百分百识别、永久后台运行或通知绝不遗漏。
6. 使用对应发行工具链构建 Archive，检查主 App/Widget 签名一致、发布描述文件和推送环境，先 TestFlight 验收，再单独发起商店提交。

这些步骤是待执行的发布工作。当前代码、项目和验证命令的交付不等于已获得开发者签名、已部署 CloudKit production、已通过 TestFlight 或已公开上架。
