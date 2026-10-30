# CC-Relay

[English](#english) · [简体中文](#简体中文)

## English

CC-Relay is a native macOS menu-bar app that switches Claude Desktop between several
signed-in accounts with one click. Each account lives in its own Claude profile directory; a
switch closes Claude Desktop and reopens it on the chosen profile.

### Features

- Automatic switching and continuation when quota is exhausted or the original Code session
  receives a real rate-limit failure. Enable **Auto-switch** in Settings; CC-Relay refreshes
  alternatives, selects a usable account, and hands the original work to its verified target
  conversation. No switch-confirmation or wait-for-tasks dialog is needed.
  It switches whenever the account is spent and another one is ready, also with nothing running,
  and waits while a background command that needed approval is still running, since a switch
  would stop it. It keeps the current account, saying why, when no alternative is ready, when a
  rate limit comes again within ten minutes of a switch that a rate limit caused while the account
  still has quota, and when Claude reports the account on hold or its organization not allowed. A
  conversation that skips permission prompts moves only to an account that allows it; when no
  account with quota left does, the notice names one to turn it on in.
- One-click switching from account cards, with progress in a dialog; it asks first until you turn
  that off. If a Claude Code task is running you can wait for it, switch now, or cancel.
- Two-way sync of Claude Code conversations between the two accounts of a switch, with a backup
  of both before any write, and the last conversation reopened on the new account.
- Work continues across a switch through the CC-Relay plugin: once the new account's
  conversation runtime is verified, the original conversation goes on where it stopped.
  Background commands the person's rules already allow run in a protected worker and keep the
  same process; interrupted agents keep their IDs; WebSocket monitors are rebuilt with their
  remaining time. Commands that needed approval keep their native path and stop with the switch;
  the local receipt records them. Other conversations with work are opened when the target Desktop is the only one
  running. Artifact comment watches stay with the account that published the page, which no
  other account can open: a conversation that only watches stays there, one with work goes on
  and leaves its watch there, the panel lists them, and CC-Relay starts the conversation again
  for its watch the next time it opens that account. Reopening a conversation on that account picks
  its watch up again at the original URL, also after the conversation was compacted. Connection,
  submission, execution and completion remain distinct
  ([details and limits](docs/native-work-continuity.md)).
- Quota at a glance: plan, subscription channel, 5-hour and weekly remaining with reset times.
  Each account's buddy shows by its face and colour whether the account can be used now, and once
  the current account is out a card under it suggests the one to use: the usable account whose
  weekly limit resets soonest, with those nearly out of weekly quota last. The menu bar shows the
  current account's buddy: still, moving only when its level changes or the pointer is over it.
- Long Claude Code conversations compacted on the account they are on: before that account runs
  out of usage, and before a switch moves a conversation of 300 000 tokens or more to another
  account (prompt caches belong to an account, so the new one would re-read the whole context).
  A small Claude Code plugin in each conversation does the compacting
  (`docs/low-quota-compaction.md`).
- An automatic return to the previous account if the target fails to open.
- One-step "add account" that imports the history of your other accounts, rename, remove
  (archived, never deleted), automatic correction when Claude opens on the default profile,
  launch at login (off until you turn it on), Chinese and English.

### Risks

CC-Relay is unofficial and not affiliated with Anthropic. Before you install it:

- **How it reads quota.** While it runs, it decrypts each profile's sign-in cookie in memory and reads
  claude.ai's undocumented endpoints with it. These requests identify as Claude Desktop: the same
  User-Agent, with claude.ai as their origin. Those endpoints and Claude Code's plugin features may
  change or stop working at any time.
- **Anthropic's rules.** Its [help article](https://support.claude.com/en/articles/13189465-log-in-to-your-claude-account) prohibits third-party tools that misrepresent
  their identity to its servers. Its [legal page](https://code.claude.com/docs/en/legal-and-compliance) says developers may not collect, store
  or intermediate Claude.ai credentials or session tokens, and that it may enforce this without
  notice. CC-Relay may fall under these rules.
- **Several accounts.** Whether holding several accounts and moving work between them, by hand or
  automatically, fits the terms is yours to judge, and the risk to your accounts is yours.

### Requirements

macOS 14 or later, Claude Desktop installed (in `/Applications` or anywhere else, under any name),
Xcode command line tools with Swift 6 to build.

CC-Relay is shared as source only. To install it, run `scripts/build-app.sh`, move
`build/CC-Relay.app` into `/Applications`, and open it.

Auto-switch and auto-compact work through CC-Relay's plugin for Claude Code, which the app carries.
Turning either on asks once to install it: the plugin goes into Claude Code, and
`CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1` is set in `~/.claude/settings.json` after the old file is copied
beside it. A newer CC-Relay updates the plugin to its own copy by itself when it starts.

### Build, test, try

```bash
scripts/test-all.sh             # Swift, Node and plugin-host regressions, with explicit PASS / FAIL / SKIP
scripts/test.sh --filter Name   # selected Swift tests; omit --filter Name for all Swift tests
scripts/build-app.sh            # release build into build/CC-Relay.app (ad-hoc signed)
scripts/run-sandbox.sh          # run the app against a generated sandbox with a fake Claude
scripts/sandbox-control.sh      # drive that sandbox: sign-in, busy task, default launch, launch failure
scripts/make-icon.sh            # re-render Resources/AppIcon.icns after changing the icon or the buddy's face
```

The full local entry point builds the worker used by Node tests in the same run. Set
`CC_RELAY_TEST_BUILD_ROOT=/path/to/separate-build` to avoid sharing another run's build directory
(the default is the project's `.build`). The plugin's `.test.ts` files run in Claude Code's own
test host (`claude plugin test`) when a `claude` command is on `PATH`, with a throwaway config
folder; that host applies the load rules the Node fixtures do not. Without the command they are
reported as skipped. No plugin is installed and no real account is used. Skipped checks and real
switch/comment acceptance remain separate from passing local regressions.

### Privacy

The menu-bar app's direct network access is limited to three claude.ai endpoints (account, usage, subscription details)
read with the sign-in cookie of each profile, decrypted in memory with the "Claude Safe Storage"
keychain item. No analytics, no update checks, no other servers. Cookies, session keys and tokens
are never written to disk or logs; e-mail addresses in logs are masked. Data lives in
`~/Library/Application Support/CC-Relay/`.

The plugin runs compaction and continuation inside Claude Code, consuming that account's usage
and using its existing tool permissions and network access. Native continuity reads the original
conversation's structured history and stores task IDs, evidence locations and recovery receipts;
it does not copy credentials or grant the new account access to the old account's resources.

### Documentation

`docs/行为说明.md` (behaviour, Chinese), `docs/手动测试清单.md` (manual test checklist, Chinese),
`docs/architecture.md` (design contract), `docs/low-quota-compaction.md` (the compaction plugin),
[`docs/native-work-continuity.md`](docs/native-work-continuity.md) (native work continuity and its limits).

### License

MIT License, © 2026 CC-Relay contributors. Not affiliated with Anthropic. The wordmark's font,
DynaPuff (`Resources/Fonts`), is under the SIL Open Font License 1.1.

## 简体中文

CC-Relay 是一个原生 macOS 菜单栏应用，让 Claude 桌面端在多个已登录账号之间一键切换。
每个账号对应一个独立的 Claude 资料目录；切换就是关闭 Claude，再用所选账号的资料目录重新打开它。

### 功能

- **自动切换账号并续跑**：在设置开启“自动切换”后，当前额度耗尽或原 Code 会话收到真实限流错误时，
  自动刷新备选账号额度，选择可用账号，完成切换并在核验后的原会话中继续任务，不再等手动确认。
  额度用完、有别的账号可换时就换，没有任务在跑也换；需要授权才运行的后台命令还在跑时先等它结束（换号会让它停止）。
  以下情况保留当前账号并说明原因：没有可用账号；因限流换号后 10 分钟内又遇到限流，而账号额度还有余量；Claude 报告账号被暂停或所在组织不允许使用。
  开着“跳过权限确认”的会话只换到同样允许跳过的账号；有额度的账号都不允许时，提示写明去哪个账号打开。开关默认关闭。
- 点账号卡片即切换，进度显示在面板中间的对话框里；默认先问一次，可以关掉。Claude Code 任务正在运行时，可以选择等它结束再切换、
  立即切换或取消。
- 切换时在两个账号之间双向同步 Claude Code 对话，写入前先备份两边；切换后自动回到上一段对话。
- 换号后原有工作接着做（通过 CC-Relay 插件）：目标账号的会话通过核验后，原会话从中断处继续。
  权限规则已经直接放行的后台命令交给托管程序运行，换号时保留同一个进程；被打断的子代理保留原编号；
  WebSocket 监听按剩余时限重建。需要授权的命令照原样运行，换号时会停下，并记在本地回执里。
  还有工作的其他会话，在目标账号的 Claude 是唯一开着的 Claude 时自动打开。
  Artifact 网页属于发布它的账号，评论监听不随换号转过去：只挂着监听的会话留在原账号，面板列出这些会话，CC-Relay 下次打开这个账号时会为监听把它们重新打开；
  同一账号里普通重开会话时会按原网址补接原有监听（会话压缩过也一样），并在宿主的会话授权条件允许时恢复原有自动回复；两者分别核验，受阻时如实提示。
  连上、提交、执行和完成分别说明（[工作方式与限制](docs/native-work-continuity.md)）。
- 额度一目了然：套餐、订阅渠道、5 小时和每周的剩余额度及重置时间。每个账号的头像小伙伴用表情和
  颜色表示它现在能不能用；当前账号用不了时，下面的推荐卡片给出该用哪个：能用的账号里每周限额最先重置的那个，每周额度快用完的排最后。
  菜单栏里是当前账号的小伙伴：平时静止，额度换到另一档或鼠标移上去时才动。
- 长的 Claude Code 对话在所在的账号上压缩：账号额度用完前压一次；切换时要带走的对话有 30 万 tokens
  以上，先在当前账号上压好再切（提示缓存按账号区分，不压的话新账号要把整段上下文重新计入额度）。
  压缩由装在 Claude Code 里的小插件完成（`docs/low-quota-compaction.md`）。
- 目标账号打不开时自动回到原账号。
- 一步添加账号并导入其他账号的历史会话；改名；移除（归档，不删除）；Claude 落在默认账号时自动纠正；
  开机启动（默认关闭，在设置里打开）；中英文界面。

### 风险与须知

CC-Relay 是非官方工具，与 Anthropic 无关。安装前请先了解：

- **怎么读额度**：应用运行时，它会在内存里解密各资料目录的登录 Cookie，用它读取 claude.ai 没有公开文档的接口。这些请求标明的身份是 Claude 桌面端（User-Agent 和来源都与桌面端一致）。这些接口和 Claude Code 的插件功能都可能随时变化或失效。
- **官方规定**：Anthropic 的[帮助文档](https://support.claude.com/en/articles/13189465-log-in-to-your-claude-account)禁止第三方工具向其服务器谎报身份；[法律文档](https://code.claude.com/docs/en/legal-and-compliance)写明开发者不得收集、存储或中转 Claude.ai 的凭据和会话令牌，并可以不事先通知就采取措施。CC-Relay 可能属于这些规定的范围。
- **多账号**：持有多个账号、手动或自动在账号之间转移工作是否符合条款，请自行判断，账号风险由你自己承担。

### 环境要求

macOS 14 及以上；已安装 Claude 桌面端（放在 `/Applications` 或别处、改过名都能找到）；构建需要带 Swift 6 的 Xcode 命令行工具。

CC-Relay 只以源码发布。安装方法：运行 `scripts/build-app.sh`，把生成的 `build/CC-Relay.app` 拖进"应用程序"，再打开它。

自动切换和自动压缩要靠 CC-Relay 的 Claude Code 插件完成，插件就在 App 里。第一次打开其中一项时会问一次是否安装：
安装会把插件装进 Claude Code，并在 `~/.claude/settings.json` 里设置 `CLAUDE_CODE_ENABLE_FUNCTION_HOOKS=1`，
改之前先把原文件复制一份放在旁边。新版 CC-Relay 启动时会自己把插件更新到新版。

### 构建、测试、体验

```bash
scripts/test-all.sh             # Swift、Node 与插件宿主回归，明确输出 PASS / FAIL / SKIP
scripts/test.sh --filter Name   # 定向 Swift 测试；去掉 --filter Name 则运行全部 Swift 测试
scripts/build-app.sh            # 发布构建，生成 build/CC-Relay.app（本地签名）
scripts/run-sandbox.sh          # 在生成的沙盒里运行应用，使用模拟的 Claude
scripts/sandbox-control.sh      # 操控沙盒：模拟登录、运行中的任务、默认启动、打开失败
scripts/make-icon.sh            # 修改图标或小伙伴的脸后，重新生成 Resources/AppIcon.icns
```

完整本地入口让 Node 测试使用同一次运行构建的执行程序。可设置
`CC_RELAY_TEST_BUILD_ROOT=/path/to/separate-build` 使用独立构建目录，避免争用其他构建；默认仍为项目的 `.build`。
插件的 `.test.ts` 在 `PATH` 中有 `claude` 命令时，用临时配置目录交给 Claude Code 自带的测试宿主运行（`claude plugin test`），
它会检查 Node 夹具不检查的加载规则；没有该命令时明确显示跳过。
脚本不安装插件、不使用真实账号；跳过项及真实换号、评论回复验收不算作本地回归通过的证据。

### 隐私

菜单栏应用直接访问的网络接口只有 claude.ai 的三个接口（账户、用量、订阅详情），用各资料目录的登录 Cookie 读取，
Cookie 借助钥匙串里的"Claude Safe Storage"在内存中解密。没有统计、没有更新检查、没有其他服务器。
Cookie、会话密钥和令牌从不写入磁盘或日志，日志中的邮箱会打码。数据保存在
`~/Library/Application Support/CC-Relay/`。

插件在 Claude Code 内执行压缩和续跑，会使用该账号的额度、已有工具权限及工具自身的网络访问。
原生续接会读取原会话的结构化历史，保存任务 ID、证据位置和续接回执；不会复制登录凭据，
也不会替新账号取得原账号资源的访问权限。

### 文档

`docs/行为说明.md`（行为说明）、`docs/手动测试清单.md`（手动测试清单）、`docs/architecture.md`（设计约定）、`docs/low-quota-compaction.md`（压缩插件）、[原生工作续接](docs/native-work-continuity.md)（机制、限制与验证范围）。

### 许可

MIT 许可，© 2026 CC-Relay contributors。与 Anthropic 无关联。标志文字用的字体 DynaPuff（`Resources/Fonts`）采用 SIL Open Font License 1.1。
