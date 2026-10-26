---
target: 当前原生 UI 与交互
total_score: 19
max_score: 36
na_heuristics: 8
p0_count: 0
p1_count: 4
target_identity: "file:../../NetMounter/Sources/NetMounter/Views/ServerListView.swift"
target_fingerprint: "sha256:3d83d80f44957108a342fd9e6319d1762d7da8717ca364c9f97ae20ff611a380"
target_path: ../../NetMounter/Sources/NetMounter/Views/ServerListView.swift
timestamp: 2026-10-25T12-07-59Z
slug: ces-netmounter-views-serverlistview-swift-beb213b4
---
Method: design review only (detector not applicable, native platform)

## 总体结论

**有值得改进的问题，但我不建议先大规模换肤。优先级应该是：保存与权限边界、状态反馈、连接验证、自动挂载的可控性，然后再整理视觉层级。**

我核对了当前源码中的服务器列表、添加/编辑、网络发现、设置，以及相关挂载、密码和授权流程。**原生界面工具读取 NetMounter 时持续超时，未能取得当前弹窗截图**，因此下面区分了“源码确认的问题”和“需要实际界面验证的项目”。不能据此断言某处已经发生文字裁切、对比度不合格或 VoiceOver 失效。本轮没有修改源码、配置、密码或挂载状态，也没有进行连接失败或授权失败的实测。

### 目前做得好的地方

- **产品结构集中**：菜单栏入口、服务器列表、Finder 和固定文件夹，适合日常快速访问共享。
- **部分信息按需展开**：高级设置使用折叠区，字段有示例；表单有取消，删除有确认。
- **已有一些明确反馈和保护**：复制分享链接有提示；开机自启失败会回退开关；底层已有挂载去重保护。分享链接也没有包含密码字段。相关实现见 [服务器列表](../../NetMounter/Sources/NetMounter/Views/ServerListView.swift)、[设置](../../NetMounter/Sources/NetMounter/Views/SettingsView.swift#L156)、[配置模型](../../NetMounter/Sources/NetMounter/Models/ServerConfig.swift#L100)。

## 五项优先问题

### 1. [P1] 保存配置不等于保存成功；密码与系统授权的边界不清楚

**源码确认：**

- 编辑时如果旧密码读取失败，密码框会保持空白；随后点击保存，会进入“删除已有密码”的分支。也就是说，**读取失败可能被当成用户主动清空密码**。
- Keychain 写入失败和配置文件写入失败没有反馈到表单，界面仍然关闭。
- 首次保存 NFS 配置会启动持久免密码挂载辅助程序的安装。系统管理员授权弹窗存在，但保存前没有专门说明用途、持久影响和“暂不设置”的选择。

这会影响用户最基本的信任：“我只是改了名称，为什么密码没了？”“刚才保存到底成功了吗？”“为什么保存服务器需要系统管理员密码？”

**建议：**
1. 默认保留已有密码；把“替换密码”和“删除密码”变成明确操作。
2. 保存失败时保留表单，指出失败的是配置还是密码，允许重试。
3. 将“保存 NFS 配置”和“启用免重复授权挂载”拆开，后者先说明再由用户决定。

证据：[密码读取与保存](../../NetMounter/Sources/NetMounter/Views/ServerDetailView.swift#L168)、[保存及 NFS 安装入口](../../NetMounter/Sources/NetMounter/Views/ServerDetailView.swift#L235)、[配置写入错误处理](../../NetMounter/Sources/NetMounter/ViewModels/AppState.swift#L60)。对应方向：`$impeccable harden`。

### 2. [P1] 连接和断开结果不够可见，用户容易反复点击

详细状态主要藏在服务器图标的悬停提示里；卡片没有持续可见的状态文字。断开失败时，`isMounted` 仍为真，颜色仍优先显示绿色——**卷确实仍挂载着，但刚才的操作失败没有得到明显反馈**。

连接按钮也没有随进行中状态禁用。底层会拒绝同一配置的重复挂载请求并返回忙碌错误，所以不能说它必然重复挂载；问题是用户可能把正常进行中的操作误解成失败。证据：[状态提示](../../NetMounter/Sources/NetMounter/Views/ServerListView.swift#L149)、[颜色与断开失败](../../NetMounter/Sources/NetMounter/Views/ServerListView.swift#L343)、[底层去重](../../NetMounter/Sources/NetMounter/Services/MountingManager.swift#L196)。

**建议：**每张卡片增加一行简短状态，例如“连接中…”“已连接”“断开失败，仍保持连接”。错误附带具体下一步，如“检查账号”“修改共享路径”“重试”；操作期间显示进度并避免重复提交。不必增加大量弹窗。对应方向：`$impeccable clarify`、`$impeccable harden`。

### 3. [P1] “测试连接成功”容易给出过度保证，表单校验也与挂载要求不一致

“测试连接”放在认证信息附近，但实现只建立指定端口的 TCP 连接，**没有验证账号、密码或共享路径**。修改信息后，旧测试结果也没有随之清除。

此外，保存按钮只对 NFS 检查空共享路径，而挂载层要求所有协议都有具体共享/导出路径。发现界面的“添加服务器”还能创建空路径配置，并对非 NFS 立即尝试挂载。这些流程会让用户先看到“成功”或“已添加”，之后才发现无法使用。证据：[测试实现](../../NetMounter/Sources/NetMounter/Services/ConnectionTester.swift#L13)、[表单校验](../../NetMounter/Sources/NetMounter/Views/ServerDetailView.swift#L159)、[挂载要求](../../NetMounter/Sources/NetMounter/Models/ServerConfig.swift#L81)、[发现添加流程](../../NetMounter/Sources/NetMounter/Views/DiscoveryView.swift#L127)。

**建议：**
- 先采用最小修正：改为“检查服务器可达性”，结果写“端口可达，尚未验证账号与共享”。
- 相关字段变化后清除结果；检查期间显示进度。
- 保存校验与实际挂载要求一致；发现到主机但未选择共享时，进入预填好的详情表单，不直接创建不可挂载目标。

对应方向：`$impeccable clarify`、`$impeccable harden`。

### 4. [P1] 自动挂载不是一个可预测的“开关”

关闭自动挂载会清空所有网络规则，而不是暂停；开关是否开启又只看规则数组是否非空，没有看规则的启用状态。

从发现界面添加共享时，还会自动记录当前网络规则，并立即尝试连接非 NFS 共享。**一个“＋”实际承担了添加、启用自动化和连接三种含义**，与手动添加流程不一致。证据：[自动挂载开关](../../NetMounter/Sources/NetMounter/Views/ServerDetailView.swift#L107)、[发现添加的附带行为](../../NetMounter/Sources/NetMounter/Views/DiscoveryView.swift#L127)。

**建议：**关闭时保留规则；显示简短条件摘要，例如“在已记录网络中自动连接”。添加流程明确区分“保存”和“保存并连接”，自动连接条件也应让用户知情确认，不必先做复杂规则编辑器。对应方向：`$impeccable clarify`、`$impeccable harden`。

### 5. [P2] 日常主操作与管理操作的层级混在一起，首次使用缺少指引

每张卡片在服务器名称旁放了连接、Finder、复制链接、编辑、删除五个近似等权重的图标按钮。固定 380 宽的弹窗里，这种结构会挤占名称空间；**是否已经裁切仍需截图验证**。

列表为空时也没有任务指引，只有顶栏图标。证据：[卡片操作布局](../../NetMounter/Sources/NetMounter/Views/ServerListView.swift#L174)、[空列表结构](../../NetMounter/Sources/NetMounter/Views/ServerListView.swift#L45)、[弹窗宽度](../../NetMounter/Sources/NetMounter/AppDelegate.swift#L53)。

**建议：**
- 主界面突出“连接”和“打开”；复制链接、编辑、删除移入“更多”菜单，保留所有功能。
- 未添加服务器时显示：“添加 NAS 或网络共享”，提供有文字的添加入口，网络发现作为次入口。
- 保留现有玻璃/渐变风格，先降低操作噪声。真正的改进是让用户一眼知道“现在能不能打开”，不是换一套装饰。

对应方向：`$impeccable distill`、`$impeccable onboard`。

## 另一个需要修正的具体问题

**[P2] 固定文件夹选择器可能保存错误目标。**选择窗口只是默认打开共享根目录，并未限制选择范围。若选择共享外的文件夹，代码会将其末级名称当成共享内的相对路径；选择共享根目录本身也有类似问题。随后可能打开与用户选择不同的位置。

应校验选择项属于该共享，并明确处理根目录；不合法时说明原因，不静默替换目标。证据：[固定文件夹选择器](../../NetMounter/Sources/NetMounter/Views/ServerListView.swift#L515)。

## 不同用户会遇到的阻碍

以下是流程推演，不是实际用户测试：

| 用户 | 主要阻碍 |
|---|---|
| 第一次连接 NAS 的用户 | 空列表不知道从哪里开始；把端口可达理解为密码正确；失败后不知道该改什么。 |
| 家庭/办公室切换的常用用户 | 想临时暂停自动挂载，却删除了规则；添加共享时发生未说明的自动连接。 |
| 键盘或辅助技术用户 | 图标按钮缺少明确动作文本；整张卡片使用点击手势打开，需验证键盘与 VoiceOver 的可操作性。 |

## 需要补充实测的部分

- **视觉与无障碍**：长服务器名、多固定文件夹、浅色/深色模式、减少透明度、减少动态效果，以及实际键盘焦点顺序。目前不能给出对比度或可访问性合格结论。
- **中文完整性**：资源中有“协议Protocol”，且部分新增字段和帮助文案未被中文资源覆盖；应核对实际显示和资源加载。见 [中文资源](../../NetMounter/Sources/NetMounter/Resources/zh-Hans.lproj/Localizable.strings)。
- **原生设置入口**：源码中的系统 `Settings` 场景仍是占位文字，而菜单栏内另有真实设置页。需要验证原生设置快捷键是否进入错误页面。见 [应用入口](../../NetMounter/Sources/NetMounter/NetMounterApp.swift)。

## 启发式初评

这是用于排序的**源码初评，不是可用性测量**；未看到渲染界面，所以视觉美感一项不评分。0 为缺失，4 为优秀。

| 维度 | 分数 | 主要依据 |
|---|---:|---|
| 系统状态可见性 | 2/4 | 有状态，但错误主要依赖悬停 |
| 与用户语言匹配 | 3/4 | 字段有示例，测试语义需要修正 |
| 用户控制与退出 | 2/4 | 有取消；自动化关闭会删除规则 |
| 一致性 | 2/4 | 手动添加与发现添加行为不同 |
| 错误预防 | 2/4 | 有确认和底层校验，表单仍有缺口 |
| 识别优于记忆 | 2/4 | 图标动作和网络规则不够直观 |
| 操作效率 | 2/4 | 有快速入口，主次操作仍混杂 |
| 视觉美感与极简设计 | 不评分 | 缺少当前渲染证据 |
| 错误恢复 | 2/4 | 有错误信息，缺少就地恢复入口 |
| 帮助与说明 | 2/4 | 有局部帮助，权限解释不足 |
| **合计** | **19/36** | **可用基础存在，关键交互需改进** |

**最值得保留的是紧凑的菜单栏工具结构。最值得改变的是：让每一次点击的含义、结果和下一步都明确。**
