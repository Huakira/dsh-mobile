# iOS 视口跳动修复交接文档（2026-11-15 深夜）

> 交给下一位。前情：本 fork（whaleness = Huakira/dsh-mobile，branch `smooth-streaming`）
> 目标是把 dsh-mobile iOS 端的聊天体验做到 Claude App 级顺滑。用户逐轮真机验证过，
> 当前反馈：**「大大进步」**，剩两个问题：①流式输出中偶发**半行卡住**（未解决，见 §3）；
> ②开新对话**闪烁**一下然后渲染才稳定（未定位，见 §4）。

## 1. 环境速查

- 仓库 `/Users/huake/codestart/whaleness`，branch `smooth-streaming`，remote origin=Huakira/dsh-mobile（fork），upstream=Clarklevis1995/dsh-mobile。
- 构建：`export JAVA_HOME=/opt/homebrew/opt/openjdk@21 PATH=$HOME/go/bin:/opt/homebrew/opt/openjdk@21/bin:/usr/local/go/bin:$PATH`
  `xcodebuild build -project DeepSeekHarnessMobile.xcodeproj -scheme DeepSeekHarnessMobile -configuration Release -destination 'generic/platform=iOS' -allowProvisioningUpdates DEVELOPMENT_TEAM=RXX254HN89`
- 装机：`xcrun devicectl device install app --device 8D5069AE-5DC1-58E7-9CF1-6912D160752B <DerivedData>/Build/Products/Release-iphoneos/DshMobile.app`（真机 monsoonbread，bundle `com.huake.dshmobile.dev`；手机上另有原作者的 `com.lichaofan.dshmobile`，互不干扰）
- 测试：`xcodebuild test -project … -scheme TeamCompatibilityTests -destination 'platform=iOS Simulator,id=4C58D1C1-FAB2-46E7-BA4F-966FEE2FA5CD' -only-testing:DeepSeekHarnessMobileTests/ConversationViewportLayoutTests -only-testing:DeepSeekHarnessMobileTests/StreamingMarkdownTests CODE_SIGNING_ALLOWED=NO IPHONEOS_DEPLOYMENT_TARGET=17.0`，当前 **28/28 通过**。
- 服务器端（dsh 网关）另外两条线的交接在 gitops `Huakira/gitops` 仓 `dsh/changes/2026-11-14-mobile-gateway.md` 与 `dsh/changes/2026-11-15-sessions-outage.md`，本文件不重复。

## 2. 已完成的修复（本会话 + 上会话，已提交到本分支）

提交纪律：**应提交** `DeepSeekHarnessMobile/Components/ConversationViewport.swift`、`DeepSeekHarnessMobile/Views/ConversationView.swift`、`DeepSeekHarnessMobileTests/GatewayProtocolTests.swift`；**永远不要提交** `DeepSeekHarnessMobile/Views/WorkspaceView.swift` 与 `DeepSeekHarnessMobile.xcodeproj/project.pbxproj`（两者是本机签名/SDK 兼容的本地补丁，见 §5）。

1. **恢复会话遮罩**（ConversationView.swift `shouldShowHistoryPresentationMask`）：遮罩只在 `isPreparingHistoryPresentation` 为 false 时移除，即撑到 `onBottomAlignmentCompleted` 贴底链收敛，不再提前暴露中间态。上会话真机已确认恢复跳动消失。
2. **live 贴底提交改 ChatLayout 原生动画**（ConversationViewport.swift `render()` 的 apply 分支，`animateLiveTailCommit`）：`keepTail && !initialContentRevealPending && disclosureAnchor == nil && batch?.projectionEpoch == nil` 时，开 `chatLayout.keepContentOffsetAtBottomOnBatchUpdates` + `animatingDifferences: true`——注入行插入、流式→最终切换（reload 自带交叉淡入）的行帧与 offset 在同一动画块内滑动。**这是用户确认「大大进步」的那一版**。
3. **preserve 瞬移抑制**（`isTailCommitPending`，finalize 的 defer / 推迟收尾丢弃路径 / stopInertialScrolling 清除）：防止 `preservePinnedBottomAfterLayout` 在提交布局过程里抢在动画前瞬移。
4. **流式逐帧平滑追随**（`chaseStreamingTail()`，由 reveal display link 驱动，exp(-dt·9) 与文字 reveal 同节奏；`updateRevealDisplayLink` 排水时 `followStreamingTail()` 精确收尾；reveal link 存活期间 preserve 与逐行即时跟随让位）。**用户反馈此版没有解决半行**——见 §3，但机制本身保留（跟随确实平滑了）。
5. 回归测试 `testTailCommitDoesNotSnapDuringApplyAndFollowsTailSmoothly`、测量测试 `testMidTailInsertDisplacesStreamingRowInstantly`（后者是诊断工具，打印 assistantY/offset/pending，不写断言）。

### 排查记录（避免重走弯路）

- 逐轮探针实测：注入行插入时 preserve 被抑制后 offset 仍 80→350 瞬移，元凶是 **ChatLayout 自身批量更新锚定**（不经过任何自定义钩子）——这就是 #2 换用 `keepContentOffsetAtBottomOnBatchUpdates` 的依据。**坑：ChatLayout 在「插入点在可见行上方」时会按可见像素锚定 offset，数学上恰好落在新区底部，动画跟随永远 delta=0。**
- `ConversationTimeline.publish(_:)` 是**整表替换**语义，不是 append——写测试时追加必须重发全量列表。
- 测试想冻结「布局完成、finalize 未跑」的中间态，用现成的 `controller.historyDiffableCompletionGateForTesting`（模式参考同文件 `testInitialContentFadesOnlyAfterCommitAndPositionAreStable`）。

## 3. 未解决问题 A：流式输出中「半行卡住」（最高优先）

用户最新反馈：平滑追随版仍「有半行卡住」。场景=流式输出进行中（用户确认过）。

**关键推断（下一手从这里开始）**：视口级滚动修复连续两版无效，问题大概率**在 StreamingAssistantCell 内部**，不是视口滚动：

- 主嫌疑：**cell 高度 = `StreamingMarkdownDocument.height(width:)`（TextKit 测量）与实际渲染高度差半行**——CJK 行高/行距的取整（ceil vs 四舍五入、lineSpacing 累积）会让最后一行被 cell 边界裁掉一半，且「卡住」到下一行增长才恢复。验证：真机截图半行状态 → 对比 `document.height()` 与 cell 实际内容高度（差值应为 <1pt 的固定小数）；修复方向 = 高度向上取整或给 cell 内容加半点 bottom padding。
- 次嫌疑：reveal 逐帧推进文字但**行高按行更新**，reveal 边界正好切在一行中间时被 tail fade 渲染成半行，停顿时静止（tailFade 渐变边）。验证：关掉 tailFade 试是否复现。
- 再次嫌疑：行高更新（invalidate）与 cell 内容绘制不同帧（布局一帧用旧高度），表现为一帧半行闪动——如果是「闪一下就正常」选这条，「持续卡半行」选第一条。

对照素材：`StreamingMarkdownTests.testCompareWithFinalRenderer`（样例 446pt vs MarkdownUI 最终渲染 603.08pt，差 157pt，分块对比图测试里可导出）。

## 4. 未解决问题 B：开新对话闪烁

现象：新建会话打开时闪一下，然后渲染才稳定。未定位。线索：

- 新会话首条内容到达时 `finalize` 的顺序是 `collectionView.isHidden = false`（apply 完成块内）→ 之后才 `needsInitialBottomPlacement → placeInitialPositionIfNeeded → scrollToBottom`，同步块内不应有帧边界，但 **contentSize 未就绪时 scrollToBottom 可能落偏，下一帧修正 = 闪**。
- 首屏 reveal 自带 0.18s opacity 渐入（`conversation-content-reveal`），若遮罩（`isPreparingHistoryPresentation`）在渐入开始前就移除，会看到「实内容一闪 → 回落重淡入」。新会话是否真的设置了 `store.isPreparingConversation` 需要验证（它只在历史加载路径确认过；空会话路径可能不设 → 无遮罩裸奔）。
- 建议手段：让用户录屏逐帧看，或模拟器跑起来 `xcrun simctl io recordVideo` 抓 New Session → 首条消息全程。

## 5. 本机签名补丁（不要提交！）

- `WorkspaceView.swift`：Xcode 27.0 SDK 缺上游 iOS 27.1 API（`toolbarVerticalEdge`、`.axisBehavior`），本地 stub。同上会话约定。
- `project.pbxproj`：上游在 **Release** 配置块硬编码了 `PRODUCT_BUNDLE_IDENTIFIER[sdk=iphoneos*]`/`DSH_SHARE_APP_GROUP[sdk=iphoneos*] = com.lichaofan.dshmobile…`（原作者 id），把 `config/Local.xcconfig` 的个人签名覆盖在真机构建上压掉了（Debug 不受影响）。本地处理：删掉这些 `[sdk=iphoneos*]` 覆盖行、给 ShareExtension/ActionExtension 的 Release 块补回 `PRODUCT_BUNDLE_IDENTIFIER = "$(LOCAL_BUNDLE_IDENTIFIER).…"`。扩展 Release 块还硬编码 `DEVELOPMENT_TEAM = T58RY5HUA7`，靠命令行 `DEVELOPMENT_TEAM=RXX254HN89` 压过，构建命令必须带。若要给上游提 PR：这是「Local.xcconfig 个性化机制在真机 Release 构建失效」的正经 bug，值得单独提。

## 6. 建议的下一步顺序

1. §3 半行：先真机截图确认是 cell 内裁切还是视口顶部裁切 → 修 TextKit 高度取整。
2. §4 闪烁：录屏定位 → 大概率是首屏 reveal 与遮罩的时序，改 `acknowledgePresentation`/`revealContentIfStable` 的先后。
3. （可选）流式/最终渲染样式对齐 157pt：目标——切换瞬间零高度差。工作量大，等 A/B 收了再说。
4. 若改 `ConversationViewport.swift`，跑 §1 的 28 个测试；它们锁住了本轮所有机制。
