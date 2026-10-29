# Holofold

[English](README.md) | **简体中文**

**在 Apple Vision Pro 上用真·立体 3D 玩 3DS 游戏。**

![Holofold 在 Apple Vision Pro 上运行：上屏立体显示，下屏在独立窗口中，用 PS VR2 Sense 手柄操作](docs/images/holofold-vision-pro.jpg)

Holofold 让 3DS 软件原生运行在 Apple Vision Pro 上。上屏以真正的立体方式显示（左右眼各看到自己的画面，相当于把 3D 滑块推到最大），可以弯成环绕的"影院"曲面屏；下屏浮在单独一个倾斜的窗口里，看向它并捏合手指即可触控。

Holofold 是 [Bifold](https://github.com/Bifold-Emu/Bifold)（Azahar 的 iOS 前端）的分支，基于 [Azahar](https://github.com/azahar-emu/azahar) 模拟器核心。

> **与任天堂、Apple 均无关联。** Holofold 不包含、不链接、也不分发任何游戏、ROM、BIOS、固件或密钥。请使用你从自己拥有的卡带中导出的游戏文件。

## 功能

- **立体 3D**：核心并排渲染左右眼画面，RealityKit 材质让每只眼睛只看到自己那一半。景深可调。
- **曲面屏**：可选把上屏弯成环绕你的弧面（20°–90°）。
- **下屏独立窗口**：像掌机下半部分一样倾斜摆放；注视 + 捏合 = 点击，捏合 + 拖动 = 滑动。
- **手柄**：PS VR2 Sense、DualSense / DualShock 4、Xbox、Switch Pro 及其他 MFi 手柄；支持用手柄陀螺仪做体感操作。
- **高清材质包**：支持 Azahar 格式的材质包（见[高清材质包](#高清材质包)）。
- **自动存档**：退出游戏时自动保存即时存档，下次启动从这里继续。
- **M5 上满速运行**：我们的测试中仅用解释器（无需 JIT）约 60 fps，内部分辨率最高 4×（每只眼 1600×960）。
- **启动直接进游戏**：没有启动器界面。
- **运行在共享空间**：游戏窗口和下屏窗口都是普通窗口，可以和其他 app 并排摆放，3D 效果照样生效。目前还没有沉浸模式。

## 当前状态

早期、实验性项目。

已测试的游戏（Vision Pro M5，解释器，未开 JIT）：

| 游戏 | 状态 |
|---|---|
| 超级马里奥 3D 大陆 | 流畅，约 60 fps；高清材质包可用 |
| 塞尔达传说 时之笛 3D | 能启动并新建游戏（输入名字正常）；还没有长时间游玩测试 |

测试过其他游戏？欢迎开 issue 反馈结果。

已知问题：

- 游戏玩几分钟后可能卡住（游戏停止绘制，但模拟器仍在运行）。我们正在排查。**解释器兼容模式**（见[配置](#配置)）可以帮助缩小范围，非常欢迎附上下文所述诊断文件的反馈。
- Vision Pro 的录屏只录一只眼，所以录出来是平面的。3D 效果要戴上头显才能看到。
- `Bifold` iOS target 是从上游保留下来的，不是本分支的重点。

## 环境要求

| | |
|---|---|
| 头显 | Apple Vision Pro，visionOS 26 或更高（在 M5、visionOS 27 上测试） |
| Mac | Apple 芯片，Xcode 27 或更高，带 visionOS SDK |
| 工具 | `brew install cmake ninja xcodegen`（CMake 3.28 或更高），Python 3 |
| Apple 账号 | **免费 Apple ID 即可**（Xcode › Settings › Accounts 添加后使用它的 "Personal Team"）。付费开发者账号额外支持"提高内存上限"权限（默认分辨率更高）和一年期签名。 |
| 磁盘 | 约 5 GB 空闲空间。首次构建核心需要 10–20 分钟。 |

### 免费账号与付费账号对比

| | 免费 Apple ID | 付费账号 |
|---|---|---|
| 构建并安装到自己的 Vision Pro | ✅ | ✅ |
| 提高内存上限（`HOLOFOLD_INCREASED_MEMORY`） | ❌ 保持 `NO` | ✅ |
| 默认内部分辨率 | 根据可用内存自动选择（2×–4×） | 最高 4× |
| 应用有效期 | 7 天，到期后在 Xcode 里重新 Run 即可（游戏和存档会保留） | 1 年 |
| 该账号同时可安装的应用数 | 3 个 | 不限 |
| 新 App ID 数量 | 每 7 天 10 个 | 不限 |
| 可选 JIT（如 StikDebug） | ✅ | ✅ |

## 构建与安装

```bash
# 1. 获取代码
git clone https://github.com/zlinoliver/Holofold.git
cd Holofold

# 2. 拉取 Azahar 2126.2 及其子模块（约 1.5 GB）并打补丁
./scripts/bootstrap.sh

# 3. 为头显构建模拟器核心（首次构建需要一段时间）
./scripts/build-core-ios.sh --sdk xros

# 4. 签名：复制模板，填入你的 Team ID 和你自己的 Bundle ID
cp App/Config/Local.xcconfig.example App/Config/Local.xcconfig
#    DEVELOPMENT_TEAM = ABCDE12345
#    HOLOFOLD_BUNDLE_ID = com.yourname.holofold
#    HOLOFOLD_INCREASED_MEMORY = NO   # 只有付费开发者账号才设为 YES

# 5. 生成 Xcode 工程并运行
xcodegen generate
open Holofold.xcodeproj   # 选择 "Holofold" scheme 和你的 Vision Pro，然后 Run
```

`App/Config/Local.xcconfig` 已被 git 忽略。没有这个文件工程也能构建：在 Xcode 的 Signing & Capabilities 中选择你的团队即可。

### 头显首次设置

1. **配对**头显和 Mac：在头显上打开 设置 › 通用 › 远程设备；在 Xcode 中打开 Window › Devices and Simulators 进行配对。
2. **开启开发者模式**：在头显上打开 设置 › 隐私与安全性 › 开发者模式，打开后重启。
3. **Bundle ID** 必须是你独有的。`com.example.holofold` 无法签名，请使用类似 `com.yourname.holofold` 的名字。
4. 用**免费**账号首次安装后，需要**信任你的证书**：设置 › 通用 › VPN 与设备管理 › 你的 Apple ID › 信任。否则应用打不开。
5. 免费账号构建的应用 7 天后过期，在 Xcode 里重新 Run 即可；覆盖安装会保留游戏和存档。

也可以用命令行构建和安装：

```bash
xcodebuild -project Holofold.xcodeproj -scheme Holofold -destination "generic/platform=visionOS" \
  -derivedDataPath build/DerivedData -allowProvisioningUpdates build
xcrun devicectl device install app --device <头显 UDID> \
  build/DerivedData/Build/Products/Debug-xros/Holofold.app
```

visionOS 模拟器只适合检查界面和布局（需先运行 `./scripts/build-core-ios.sh --sdk xrsimulator`）。它使用软件渲染器（很慢），立体材质在模拟器里只显示一只眼的画面。

## 添加游戏

1. 用你自己的 3DS **导出你自己的卡带**（导出教程见 Azahar 的文档）。Holofold 只支持**已解密**的文件（`.cia`、`.3ds`、`.cci`、`.cxi`、`.3dsx`）。
2. 检查文件是否已解密：
   ```bash
   python3 scripts/tools/ciacheck.py your-game.cia
   ```
   每个内容都应显示 `decrypted`，文件显示 `✅ usable`。内部仍加密（NCCH）的文件会被 Azahar 拒绝。
3. 把文件拷到头显上，任选一种方式：
   - 在"文件"应用中：**我的 Apple Vision Pro › Holofold**，或
   - 在 Mac 上运行：`./scripts/push-game.sh your-game.cia`。它用 `devicectl` 拷贝到应用的 Documents 目录，不会删除任何东西。
4. 打开 Holofold。`.cia` 文件会自动安装，然后启动游戏。

启动哪个游戏：

1. 如果设置了 `App/Config/Local.xcconfig` 中的 `HOLOFOLD_AUTOBOOT_TITLE_ID`（16 位 Title ID 或文件名），就启动它；
2. 否则启动你的第一个游戏（按标题排序）；
3. 如果没有你自己的游戏，启动内置的开源自制游戏 **StarCruiser7**，它同样使用立体上屏。所以新构建的应用总有东西可看。

## 高清材质包

Holofold 可以加载 Azahar 格式的自定义材质包（一个包含 `tex1_…png` 文件和 `pack.json` 的目录）。

1. 找到材质包里的材质目录，一般是 `user/load/textures/<Title ID>/`。
2. 如果材质包是为其他地区版本做的，把这个目录改名为你那份游戏的 Title ID（运行 `python3 scripts/tools/ciacheck.py your-game.cia` 可以看到）。改名后菜单文字这类区域专属材质可能对不上，会保持原样。
3. 把它拷到头显的 `Documents/Azahar/load/textures/<Title ID>/`：
   ```bash
   ./scripts/push-game.sh --textures path/to/<Title ID>
   ```
4. 启动游戏。材质在后台加载，第一次进入某个区域时可能会短暂显示原版材质。

尽量用材质包的 1080p（4×）版本，4K（8×）版本需要的内存多得多。只会用到材质本身，包里的 ReShade 预设等 PC 工具在这里不起作用。

## 游玩

- **上屏（3D）** 填满游戏窗口。拉大窗口画面就会变大。
- **下屏**在下方的独立窗口里。看向它并捏合即可点击；捏合并拖动即可滑动。
- **控制栏**在游戏窗口上方：暂停/继续、3D 景深、曲面屏、帧率、下屏（重新打开下屏窗口）、退出游戏。
- **退出**：长按 **Options / Menu** 约一秒、点击"Exit Game"，或按数码表冠。退出前会自动存档，下次启动从这里继续。

### 按键映射

| 3DS | PS VR2 Sense | DualSense / Xbox / Switch Pro |
|---|---|---|
| 摇杆（Circle Pad） | 左摇杆 | 左摇杆 |
| 十字键 | 右摇杆 | 十字键 |
| C 摇杆 | — | 右摇杆 |
| A / B | ○ / ✕ | 右 / 下 按键 |
| X / Y | △ / □（R2 也是 Y） | 上 / 左 按键 |
| L / R | L1 / R1 | L1 / R1（LB / RB） |
| ZL / ZR | L2 / — | L2 / R2（LT / RT） |
| START | Options（长按退出） | Menu（长按退出） |
| SELECT | Create | Options / View |
| 陀螺仪 | — | 手柄陀螺仪（手柄平放 = 掌机竖直拿着） |

PS 键和 Xbox / Home 键被 visionOS 系统占用，应用收不到。

## 配置

构建设置（在 `App/Config/Local.xcconfig` 中）：

| 设置 | 默认值 | 含义 |
|---|---|---|
| `HOLOFOLD_BUNDLE_ID` | `com.example.holofold` | 你的 Bundle ID（必填） |
| `HOLOFOLD_INCREASED_MEMORY` | `NO` | 提高内存上限权限（付费账号） |
| `HOLOFOLD_AUTOBOOT_TITLE_ID` | 空 | 要启动的游戏（Title ID 或文件名） |
| `HOLOFOLD_AUTO_RESUME` | `YES` | 从自动存档继续 |

启动参数（Xcode › Edit Scheme › Run › Arguments，例如 `-resolutionFactor 3`）：

| 参数 | 默认值 | 含义 |
|---|---|---|
| `-resolutionFactor N` | 自动（根据可用内存） | 内部分辨率，1–6。没有提高内存上限权限时，过高的值可能导致应用被系统关闭。 |
| `-visionStereoDepth N` | `100` | 3D 景深，10–100 |
| `-visionCurvedScreen YES/NO` | `YES` | 曲面上屏 |
| `-visionCurveDegrees N` | `50` | 弯曲角度，20–90 |
| `-motionControls YES/NO` | `YES` | 手柄陀螺仪 |
| `-customTextures YES/NO` | `YES` | 加载高清材质包 |
| `-interpreterCompat YES` | `NO` | 解释器兼容模式：关闭较新的解释器加速，用于排查卡死（会更慢） |
| `-autoboot <Title ID 或文件名>` | — | 与 `HOLOFOLD_AUTOBOOT_TITLE_ID` 相同，只对本次运行生效 |

**JIT（可选）**：在 visionOS 上启用 JIT 需要类似调试器的辅助工具，例如 StikDebug 的通用脚本。不启用时使用解释器，在 M5 上大多数游戏都能满速运行。

## 故障排查与诊断

Holofold 会在它的 Documents 目录中写入诊断文件：

| 文件 | 内容 |
|---|---|
| `vision-diag.log` | 启动选择、检测到的手柄、内存和分辨率、每 30 秒一行性能数据、退出、卡死 |
| `hang-game-*.txt` / `hang-emu-*.txt` | 游戏停止绘制或模拟器停滞时自动写入：模拟线程的采样，包括模拟 CPU 的 PC |
| `Azahar/log/azahar_log.txt` | 模拟器核心日志 |

用下面的命令取回：

```bash
xcrun devicectl device copy from --device <UDID> --domain-type appDataContainer \
  --domain-identifier <你的 Bundle ID> --source Documents/vision-diag.log --destination ./vision-diag.log
```

在 issue 中贴日志前，请先删掉其中的个人路径。

## 参与贡献

**欢迎提交 Pull Request！** Holofold 还很年轻，有很多可以改进的地方。特别欢迎以下方向的帮助：

- 排查卡死问题（解释器正确性、HLE 服务）
- 性能和帧节奏（60 fps 内容在 90 Hz 显示器上）
- 沉浸模式（Compositor Services）和更好的曲面屏几何
- 按键自定义、手柄震动
- 本地化、文档、在 M2 头显上测试

贡献方式：

1. Fork 本仓库，从 `main` 创建分支（`feature/…` 或 `fix/…`），每个 PR 只做一件事。
2. 对 Azahar 核心的修改放在 `patches/azahar/` 中（在 `external/azahar` 里用 `git diff` 重新生成补丁）。不要提交 `external/` 或 `build/`。
3. 用内置的开源自制游戏（StarCruiser7、Craftus 等）测试，并说明你是怎么测试的。
4. 提交时签名（`git commit -s`，即 [Developer Certificate of Origin](https://developercertificate.org/)）。贡献以 GPL-2.0-or-later 协议接收。
5. 安装提交前检查：`ln -sf ../../scripts/check-private.sh .git/hooks/pre-commit`。每个 Pull Request 也会运行同样的检查。

**绝对不要**在 issue、Pull Request 或讨论中发布游戏、ROM、BIOS / 固件、密钥，或指向它们（以及获取它们的工具）的链接。此类内容会被删除，相关请求会被关闭。详见 [CONTRIBUTING.md](CONTRIBUTING.md)（英文）。

## 致谢

Holofold 的诞生离不开以下项目和背后的开发者：

- **[Azahar](https://github.com/azahar-emu/azahar)**，Holofold 所基于的 3DS 模拟器，以及它的前身 **Citra**。GPL-2.0-or-later。
- **[Bifold](https://github.com/Bifold-Emu/Bifold)**，Holofold 分支自的 iOS 前端：AzaharCore C API、iOS JIT、解释器加速和手柄层。GPL-2.0-or-later。它的原始 README 保留在 [docs/BIFOLD.md](docs/BIFOLD.md)。
- **[CitraVR](https://github.com/amwatson/CitraVR)**（作者 Amanda M. Watson）。它的立体面板和曲面屏模式启发了 Holofold 的显示设计（未使用 CitraVR 的代码）。
- **[MoltenVK](https://github.com/KhronosGroup/MoltenVK)**（Apache 2.0），把 Vulkan 带到 Metal 上；以及 **dynarmic**、**oaknut**、**openal-soft** 等 Azahar 依赖的其他库，各自遵循自己的协议。
- 内置自制游戏的作者：**2048**，Carlos "0rientd" Henrique（MIT）；**Anarch**，Miloslav Číž 和 blitzdoughnuts（CC0）；**Craftus Reloaded**，Kemal Afzal "RSDuck"（MIT；材质由 XSSheep 制作，CC BY-SA）；**HexIsoPath** 和 **Yahtzee3DS**，LiquidFenrir（MIT / GPL-3.0）；**StarCruiser7**，dotMizi（MIT）。协议文本在 `App/Bundled/licenses/`。

完整列表见 [CREDITS.md](CREDITS.md)。

## 许可证

Holofold 采用 **GNU General Public License v2.0 or later** 协议（见 [LICENSE.txt](LICENSE.txt)），与 Azahar 和 Bifold 相同。第三方组件保留各自的协议（见 [CREDITS.md](CREDITS.md)）。如果你分发构建产物，必须同时提供对应的源代码。

## 免责声明

Holofold 是独立的非商业项目，**与任天堂和 Apple 没有任何关联，也未获得其认可或赞助**。"Nintendo 3DS" 是任天堂的商标；"Apple Vision Pro" 和 "visionOS" 是 Apple Inc. 的商标。此处使用这些名称仅用于说明兼容性。

截图中的游戏画面来自作者用自己的正版卡带导出的游戏，仅用于展示模拟器效果；游戏及其商标归各自权利人所有。

Holofold 不包含、不链接、也不分发任何受版权保护的游戏、ROM、BIOS、固件或密钥，本项目也不会提供它们。请购买你玩的游戏，并从你自己的硬件中导出，以支持游戏开发者。
