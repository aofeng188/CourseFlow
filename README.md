# 课序 · CourseFlow

大学课表的原生 iOS App。把课表、学校作息表和临时调课整理成真实的上课时间，在首页、小组件、实况活动与系统日历中查看。

工程为 `CourseFlow.xcodeproj`，主 Scheme 为 `CourseFlow`，App 显示名称为「课序」。使用 Swift 6、SwiftUI、SwiftData 与 Apple 原生系统框架；部署目标为 iOS 26，使用 Xcode 27 / iOS 27 SDK 构建。当前是本地开发工程，尚未完成签名真机验收或 App Store 发布。

开始使用见 [简明使用说明](docs/USAGE.md)，涵盖学期作息、示例文件导入、精细改课、提醒日历与备份恢复。

没有付费开发者账号时，可选择独立的 `CourseFlowTrial` scheme，用普通 Apple 账号的 Personal Team 在自己的 iPhone 上免费签名试用。未签名试用 IPA（约 5 MiB，包含新版图标和 AI 文本导入）可在 [Releases](../../releases/latest) 下载，也可用 `Scripts/package_ipa.sh` 自行打包到 `dist/`；安装步骤见 [免费账号试用与 IPA 安装](docs/INSTALL-IPA.md)。IPA 仍须个人签名才能安装，试用版暂时停用 iCloud、小组件与实况活动。

详见 [当前时间提示与学校调休](docs/OFFICIAL-HOLIDAYS.md)。最新版试用包为 1.0（4），SideStore 桌面名称为 `CourseFlow`。

## 已实现的功能

- 课表和作息表导入：照片、相机扫描、PDF 选页、XLSX 工作表、CSV/TSV、TXT 与粘贴文字；提供原件对照、旋转/裁剪、草稿保存和逐项核对。
- [AI 文本导入](docs/AI-IMPORT.md)：一键复制提示词，把图片交给自己常用的 AI，再粘贴返回的 JSON。无需 API Key；本机解析并生成待核对草稿，缺失信息保留待补全。
- 本地 Vision 文档/文字识别和表格解析；Apple Intelligence 可用时可选择本机模型增强，也可主动使用自己配置的兼容 OpenAI Chat Completions 服务。所有识别结果都先进入可编辑草稿。
- 学期第 1 周、学校时区、教学周范围、单双周、跳周、多段上课安排、教师与教室；支持生效日期不同的作息方案，以及单次停课、调课和补课。
- 周课表按节次等高排列，课间收窄、午休和晚饭压缩为窄带，一屏可看完整天；当前节次与正在上的课高亮，已上完的课淡化。周课表当前时间线、日程列表「现在」位置、上课与课间标记；按学校时间切换昼夜图标。官方调休按节日合并提前 7 天提示，整段放假可一次确认，补班日可留待后续处理；安排确认后才生效，支持旧备份恢复。
- 首页实时状态与完整周课表：上课、课间、下一门课、今日结束等状态共用同一时间引擎；按真实教学时间检测冲突。
- 使用系统 Tab、导航与表单，在周切换控件等浮动操作中使用原生 `glassEffect()`；周切换支持「减弱动态效果」，大字号下提供更易阅读的课程列表。
- 每门课或全局的提前提醒。系统队列滚动安排最近最多 60 条，回读后显示覆盖截止时间；日历提醒覆盖的课次默认不重复发送 App 提醒。
- 独立学期日历的新增、更新、去重和移除。使用完整 EventKit 权限，只管理带本 App 标记的事件，遇到用户在系统日历中的修改会保留并提示。
- 桌面「下一节课」「今日课表」「本周课表」、锁屏小组件、灵动岛与实况活动，与 App 使用同一套课程配色。iOS 26 的系统预约 API 负责启动下一场课程的实况活动。
- Siri、聚焦搜索与快捷指令：说「课序下一节课是什么」「课序今天有什么课」即可查询，无需打开 App。
- 可选的 SwiftData / 私有 CloudKit 同步，以及 `.courseflow` 备份与 ICS 日历文件导出。云同步默认关闭，待配置开发者容器后启用。读不出的记录（如更新版本写入的数据）会被跳过并原样保留，不会因此打不开 App 或被误删。
- 最近 20 步修改可逐步撤销。

老式 `.xls` 请先另存为 `.xlsx` 或 CSV。表格识别无法保证任意学校模板都能一次正确识别；缺少星期、周次或作息时间时，需要在核对页补齐，不能把猜测的时间写入日历。

## 本地运行

先用 Xcode 打开 `CourseFlow.xcodeproj`，等待 Swift Package 依赖解析。核心领域逻辑在本地 `CourseKit` 包中；XLSX 解析使用 CoreXLSX。

本机有多个 Xcode 时，显式选择装有 iOS 27 SDK 的版本。下面的路径对应当前开发环境：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcodebuild -project CourseFlow.xcodeproj -scheme CourseFlow \
  -configuration Debug -sdk iphonesimulator \
  -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/courseflow-build CODE_SIGNING_ALLOWED=NO build
```

纯核心测试不需要日历、相机或通知权限：

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  swift test --scratch-path /tmp/coursekit-root-tests
```

在 Xcode 的运行参数中添加 `--demo` 可加载示例课表；`--uitesting` 使用内存数据库。请只在测试配置中使用这些参数。UI 测试可从 `CourseFlow` Scheme 的 Test 操作启动，选择已安装的 iOS 模拟器。

## 签名与可选云同步

将 `Config/Local.xcconfig.example` 复制为不纳入 Git 的 `Config/Local.xcconfig`，填写自己的 `DEVELOPMENT_TEAM`。`Config/Project.xcconfig` 默认设置 `COURSEFLOW_ICLOUD_ENABLED = NO`；该值通过 `CloudSyncEnabled` 写入 App 的 Info.plist。只有明确设置为 `YES`，运行时才连接私有 CloudKit 数据库。

真机签名需要配置以下标识与能力。若更换标识，需要同时更新工程、entitlements 和代码中的对应常量：

| 项目 | 当前标识 |
| --- | --- |
| 主 App | `com.courseflow.app` |
| 小组件 | `com.courseflow.app.widgets` |
| App Group | `group.com.courseflow.app` |
| CloudKit 容器 | `iCloud.com.courseflow.app` |
| 后台刷新任务 | `com.courseflow.app.refresh` |
| App 深链 | `courseflow://today`、`courseflow://course/<UUID>` |

主 App 和小组件必须属于同一开发者团队并使用相同 App Group。工程已声明 CloudKit/App Group 能力，即使运行时关闭云同步，真机签名仍需要匹配的描述文件；开发者制作纯本地测试配置时应同步调整不使用的能力。不要为通过启动检查而静默删除用户数据库。

## 验证状态与运行边界

当前主 App 与小组件已经完成签名模拟器构建及未签名 Release / iPhoneOS SDK 构建，已实际检查 iPhone 17 Pro、iPad、小屏 iPhone、深色模式和大字号纵向布局。核心包现有 90 项测试通过；App 单元与集成测试 43 项、UI 测试 16 项在 iOS 27 模拟器通过（模拟器预先授予日历与通知权限；App Group 用例需签名构建，未签名时跳过），涵盖 PDF 导入、真实日历、通知队列、Siri 查询文案与坏记录保护。准确日志与截图见 [发布与验收记录](docs/RELEASE.md)。运行验证使用 iOS 27 模拟器；iOS 26 运行、签名真机、CloudKit 跨设备同步及自配模型服务尚需实际验收。此次 Instruments 录制未完成，尚无性能测量通过结论，也尚未提交 App Store。

已排入系统的本地通知不依赖 App 常驻。后台刷新由 iOS 决定，不能保证在某个时间执行；长时间不打开 App 时，超过当前队列覆盖范围的课次不会自动获得可靠保证。需要全学期日历提醒时使用系统日历功能，并检查系统通知设置。

首页、小组件、App 通知与实况活动使用当前选中的学期。切换学期会重新安排这些系统内容；此前已经导出的其他学期日历仍会保留，需在对应学期的日历设置中管理。课程改动只有在负责人设备获得新资料并执行同步后，才会更新到系统日历。

实况活动只维护一个当前或待启动的课程，预约启动会产生系统提示。前台会在上课/课间边界更新；后台不能保证主动更新每个阶段，过期内容会退为固定课程安排。系统也可能继续保留已经结束的活动，App 下次运行时会清理。小组件刷新同样受系统调度限制。

日历由每个学期指定的一台设备负责写入，其他设备同步课表后应避免重复导出。接管时按学期标记查找唯一专属日历，相同事件建立本机记录，用户手改内容不覆盖；多个候选会停止处理。刷新课表时，只有与当前计划时间和提前提醒相符的日历事件才抑制 App 提醒；检测到手动移时间或删掉提醒后，会解除该课次的覆盖。负责人设置通过课表资料同步，并不是跨设备的实时锁；离线同时接管与账户切换需要真机验证。

隐私与数据删除方式见 [隐私说明](docs/PRIVACY.md)。

## 许可证

本项目以 [MIT 许可证](LICENSE) 开源。
