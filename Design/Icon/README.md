# 课序 App 图标

自 2026-10-09 起使用 **墨绿课格**：墨绿底色上是一周课表的白色课程块，中间亮起的珊瑚色一格代表「正在上的课」，与 App 内的主色（墨绿）和「现在」色（珊瑚红）一致。

- 图标由 [`Scripts/make_icon.swift`](../../Scripts/make_icon.swift) 用 CoreGraphics 绘制，可重复生成：

  ```sh
  swift Scripts/make_icon.swift /tmp/courseflow-icon
  ```

  输出 `AppIcon.png`（浅色）、`AppIcon-dark.png`（深色）、`AppIcon-tinted.png`（着色），均为 **1024 × 1024 不透明 PNG**，放入 `App/Assets.xcassets/AppIcon.appiconset/`；以及 360 × 360 的 `BrandMark.png` / `BrandMark-dark.png`，放入 `BrandMark.imageset`，供设置页和欢迎页使用。
- 修改配色或课格布局时，只改脚本顶部的常量，再重新生成全部文件，保证几种外观与 App 内品牌图一致。

## 历史图标

- 2026-09-11 至 2026-10-09 使用的 **01 · 靛蓝网格**（生图模型生成）保留在 [Alternatives-2026-09-11/01-靛蓝网格.png](Alternatives-2026-09-11/01-靛蓝网格.png)，其余五款候选及提示词见 [候选说明](Alternatives-2026-09-11/README.md)。
- `CourseFlow-icon-source.png`、`AppIcon-legacy.png` 和 `AppIcon-calendar-v2.png` 是更早的历史设计。
