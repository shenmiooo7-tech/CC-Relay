import Foundation
import SwiftUI

public enum L10nLanguage: String, CaseIterable, Sendable, Equatable {
    case zhHans
    case en

    /// First preferred tag wins: any `zh*` maps to simplified Chinese, anything else to English.
    public static func resolve(preferredLanguages: [String]) -> L10nLanguage {
        for raw in preferredLanguages {
            let tag = raw.lowercased().replacingOccurrences(of: "_", with: "-")
            if tag.isEmpty { continue }
            if tag == "zh" || tag.hasPrefix("zh-") {
                return .zhHans
            }
            return .en
        }
        return .en
    }

    var fileToken: String {
        switch self {
        case .zhHans: "zhHans"
        case .en: "en"
        }
    }
}

public enum L10nKey: String, CaseIterable, Sendable, Equatable {
    case productName
    case currentMarker
    case recommendedMarker
    case recommendResetsOn
    case recommendWeekNotStarted
    case recommendJoin
    case recommendCurrentUnknown
    case recommendCurrentFiveHourLow
    case recommendCurrentWeekSpent
    case recommendNoneReady
    case addAccount
    case fiveHour
    case weekly
    case notStarted
    case resetRefreshing
    case countdownHours
    case countdownHoursMinutes
    case countdownMinutes
    case resetLine
    case signInAgain
    case quotaUpdatedAt
    case quotaUpdatedShort
    case quotaUnavailable
    case quotaKeychain
    case quotaRefreshing
    case quotaTimedOut, quotaReadFailed, quotaRefused, quotaRateLimited, quotaPreviousData, quotaCachedFailure
    case channelWeb
    case channelAppStore
    case channelGooglePlay
    case switchingTo
    case stepCompactConversation
    case stepCloseClaude
    case stepSyncSessions
    case stepOpenClaude
    case stepReopenConversation
    case switchedTo
    case switched
    case switchedUnsynced
    case switchedWithUnsynced
    case switchedConversationNotOpened
    case warningBackupFailed
    case warningContinuity
    case warningOrganization
    case warningNotCompacted
    case warningWorkContinuation
    case nativeRecoveryStateContinuing, nativeRecoveryStateContinued, nativeRecoveryStateBlocked
    case nativeRecoveryRoute, nativeRecoveryReasonsVary, nativeRecoveryEndedWithSwitch
    case nativeRecoveryMissingRecord, nativeRecoveryIncompatibleRuntime
    case nativeRecoveryBlocked, nativeRecoveryRuntimeUnavailable, nativeRecoveryExpired
    case nativeRecoveryConversationUnavailable, nativeRecoveryExecutionFailed, nativeRecoveryIncomplete, openRecoveryRecords
    case watchesStayed, untitledChat, claudeNotFound
    case warningSessions
    case clauseBackup
    case clauseContinuity
    case clauseOrganization
    case clauseConversation
    case clauseNotCompacted
    case switchFailed
    case failedToCloseClaude
    case failedToOpenClaude
    case failedAdd
    case failedRemove
    case failedAutoCorrect
    case failedHistoryImport
    case reasonCouldNotReadProcesses
    case reasonTargetMissing
    case reasonTargetUnreadable
    case reasonOperationInFlight
    case reasonRefusedActive
    case reasonRefusedLast
    case reasonRefusedRunning
    case reasonRunningUnknown
    case reasonSignedInDiffers
    case reasonCancelled
    case returnedToPreviousAccount
    case transferFailedReturnedToPreviousAccount
    case transferFailedNotReopened
    case addedAccount
    case added
    case removedAccount
    case removed
    case removedPartial
    case removedCleanup
    case cleanupUnfinished
    case removingAccount
    case switchingBack
    case retry
    case dismissNotice
    case taskGuardTitle
    case taskGuardBody
    case taskGuardWait
    case taskGuardSwitchNow
    case compactFirstTitle
    case compactFirstBody
    case compactFirstWaiting
    case compactFirstSkip
    case taskGuardCount
    case taskGuardUnknown
    case cancel
    case waitingForTasks
    case waitingForSignIn
    case cancelAdd
    case importingHistory
    case closingClaude
    case openingClaude
    case duplicateAccount
    case duplicateNote
    case keepBoth
    case discardNew
    case rename
    case refreshQuota
    case hudQuotaUpdated
    case hudQuotaPartlyUpdated
    case hudQuotaFailed
    case hudQuotaNoAccounts
    case hudVersionCopied
    case hudBackupsOpened
    case hudBackupsFailed
    case hudRecoveryOpened, hudRecoveryFailed
    case remove
    case removeConfirmTitle
    case removeConfirmBody
    case nameEmpty
    case nameTooLong
    case autoCorrected
    case autoCorrectPaused
    case autoCompacted
    case autoCompactedSize
    case autoCompactedResumed
    case autoCompactedNotResumed
    case autoCompactNotResumed
    case autoCompactFailedNotResumed
    case autoCompactedBeforeSwitch
    case autoCompactedBeforeSwitchSize
    case autoCompactFailed
    case foundAccount
    case addFound
    case dismissFound
    case historyImportInterrupted
    case historyImportFailed
    case historyImportUnavailable
    case settings
    case launchAtLogin
    case autoSync
    case autoCompact
    case autoCompactPluginLive
    case autoCompactPluginLastSeen
    case autoCompactPluginNone
    case language
    case languageSystem
    case languageZhHans
    case languageEnglish
    case openBackups
    case ignoredAccounts
    case addBack
    case quitApp
    case version
    case back
    case resetTooltip
    case settingsAppearance
    case appearanceSystem
    case appearanceLight
    case appearanceDark
    case settingsGeneral
    case launchAtLoginDetail
    case settingsSwitching
    case autoSwitch
    case autoSwitchDetail
    case autoSwitchNoAccount, autoSwitchNoAccountUntil, autoSwitchNoOtherSignIn
    case autoSwitchCommandRunning, autoSwitchLimitRepeated, autoSwitchAccountRestricted, autoSwitchNotReady, autoSwitchNotReadyUntil, autoSwitchOtherAccounts
    case autoSwitchLastFailed, autoSwitchNeedsBypass
    case pluginUpdateFailed
    case reasonContinuationUnavailable, reasonTargetCannotContinue
    case autoSyncDetail
    case settingsCompaction
    case autoCompactDetail
    case autoCompactOff
    case pluginNeededForAutoSwitch
    case pluginNeededForAutoCompact
    case pluginNeededBody
    case installAndTurnOn
    case pluginInstalling
    case pluginInstallingBody
    case autoSwitchTurnedOn
    case autoCompactTurnedOn
    case pluginReloadConversations
    case pluginNotInstalled
    case pluginInstalledFeatureOff, autoSwitchNotTurnedOn, autoCompactNotTurnedOn
    case pluginClaudeCodeMissing
    case pluginSettingsUnusable
    case pluginNotFinished
    case settingsOther
    case openBackupsDetail
    case quitConfirmBody
    case quitConfirm
    case confirmSwitch
    case confirmSwitchDetail
    case switchAskTitle
    case switchAskBody
    case switchAction
    case dontAskAgain
    case dontAskAgainHint
    case switchFailedTitle
    case switchFailedBack
    case close
    case addSignInTitle
    case addSignInBody
    case addImportingBody
    case addFailedTitle
    case emptySeatTitle
    case emptySeatBody
    case undo
    case restoredAccount
    case menuRemoveCurrent
    case moreActions
    case renameTitle
    case save
    case newName

    func template(_ language: L10nLanguage) -> String {
        let pair = templates()
        switch language {
        case .zhHans: return pair.zhHans
        case .en: return pair.en
        }
    }

    public func string(in language: L10nLanguage, parameters: [String: String] = [:]) -> String {
        L10nSubstituting.apply(template(language), parameters: parameters)
    }

    private func templates() -> (zhHans: String, en: String) {
        switch self {
        case .productName:
            ("CC-Relay", "CC-Relay")
        case .currentMarker:
            ("当前", "Current")
        case .recommendedMarker:
            ("推荐", "Suggested")
        case .recommendResetsOn:
            ("周限额 {day} 重置，日期最近", "Week resets {day}, soonest")
        case .recommendWeekNotStarted:
            ("每周额度未计时", "Weekly not started")
        case .recommendJoin:
            ("{first}；{second}", "{first} · {second}")
        case .recommendCurrentUnknown:
            ("当前账号额度读不到", "current unknown")
        case .recommendCurrentFiveHourLow:
            ("当前 5 小时只剩 {percent}%", "current 5h at {percent}%")
        case .recommendCurrentWeekSpent:
            ("当前每周额度已用完", "current week spent")
        case .recommendNoneReady:
            ("暂时没有可用的账号，等额度恢复", "No account is ready; wait for quota to reset")
        case .addAccount:
            ("添加账号", "Add account")
        case .fiveHour:
            ("5 小时", "5-hour")
        case .weekly:
            ("每周", "Weekly")
        case .notStarted:
            ("未计时", "Not started")
        case .resetRefreshing:
            ("已重置，正在刷新…", "Reset, refreshing…")
        case .countdownHours:
            ("{h} 小时后", "in {h}h")
        case .countdownHoursMinutes:
            ("{h} 小时 {m} 分后", "in {h}h {m}m")
        case .countdownMinutes:
            ("{m} 分后", "in {m}m")
        case .resetLine:
            ("{time} · {countdown}", "{time} · {countdown}")
        case .signInAgain:
            ("需要重新登录", "Sign in again")
        case .quotaUpdatedAt:
            ("额度信息更新于 {time}", "Quota updated at {time}")
        case .quotaUpdatedShort:
            ("更新于 {time}", "Updated {time}")
        case .quotaUnavailable:
            ("暂时无法获取额度", "Quota unavailable")
        case .quotaKeychain:
            ("需要钥匙串授权才能读取额度", "Keychain access is needed to read quota")
        case .quotaRefreshing:
            ("正在刷新…", "Refreshing…")
        case .quotaTimedOut: ("请求超时，请刷新", "Timed out; refresh quota")
        case .quotaReadFailed: ("读取失败，请刷新", "Read failed; refresh quota")
        case .quotaRefused: ("claude.ai 拒绝了读取", "Refused by claude.ai")
        case .quotaRateLimited: ("请求太多，{time} 后再读", "Rate-limited until {time}")
        case .quotaPreviousData: ("上次数据", "Previous data")
        case .quotaCachedFailure: ("{reason} · 上次数据", "{reason} · previous data")
        case .channelWeb:
            ("网页订阅", "Web subscription")
        case .channelAppStore:
            ("App Store 订阅", "App Store subscription")
        case .channelGooglePlay:
            ("Google Play 订阅", "Google Play subscription")
        case .switchingTo:
            ("正在切换到 {name}…", "Switching to {name}…")
        case .stepCompactConversation:
            ("先压缩当前对话", "Compact the chat first")
        case .stepCloseClaude:
            ("关闭 Claude", "Quit Claude")
        case .stepSyncSessions:
            ("备份并同步会话", "Back up & sync sessions")
        case .stepOpenClaude:
            ("用 {name} 打开 Claude", "Open Claude as {name}")
        case .stepReopenConversation:
            ("打开你刚才那段对话", "Reopen your last chat")
        case .switchedTo:
            ("已切换到 {name}", "Switched to {name}")
        case .switched:
            ("已切换", "Switched")
        case .switchedUnsynced:
            ("已切换，但有 {n} 个会话没能同步", "Switched, but {n} sessions didn't sync")
        case .switchedWithUnsynced:
            ("已切换到 {name}，但有 {n} 个会话没能同步", "Switched to {name}, but {n} sessions didn't sync")
        case .switchedConversationNotOpened:
            ("已切换，但没能自动打开刚才的对话", "Switched, but the last chat didn't reopen")
        case .warningBackupFailed:
            ("已切换，但备份没有成功", "Switched, but the backup failed")
        case .warningContinuity:
            ("已切换，但没能记下当前对话", "Switched, but this chat wasn't saved")
        case .warningOrganization:
            ("已切换，但组织未能确认", "Switched, but the organization is unknown")
        case .warningNotCompacted:
            ("已切换，但对话没能先压缩", "Switched, but the chat wasn't compacted first")
        case .warningWorkContinuation:
            ("原任务未能自动接续，请查看原对话", "Work needs attention in its original chat")
        case .nativeRecoveryStateContinuing: ("正在接续", "Continuing work")
        case .nativeRecoveryStateContinued: ("接续成功", "Work continued")
        case .nativeRecoveryStateBlocked: ("接续受阻", "Work blocked")
        case .nativeRecoveryRoute: ("从 {from} 换到 {to}", "From {from} to {to}")
        case .nativeRecoveryReasonsVary:
            ("{n} 段会话没能接续，原因见本地记录", "{n} chats couldn't continue; see the local records.")
        case .nativeRecoveryEndedWithSwitch:
            ("切换时结束了 {n} 个后台命令", "Background commands ended with the switch: {n}")
        case .watchesStayed:
            ("评论监听留在了 {name}（{n} 段会话）\n切回这个账号时自动重新打开",
             "Comment watches stayed on {name} ({n}).\nSwitching back reopens those chats.")
        case .untitledChat: ("未命名会话", "Untitled chat")
        case .claudeNotFound:
            ("没找到 Claude\n装好 Claude 后重新打开 CC-Relay", "Claude wasn't found.\nInstall it, then open CC-Relay again.")
        case .nativeRecoveryMissingRecord:
            ("缺少接续记录，请打开原会话核对", "The continuation record is missing; check the chat.")
        case .nativeRecoveryIncompatibleRuntime:
            ("插件版本不匹配，请更新后重开会话", "The plugin doesn't match; update it, then reopen the chat.")
        case .nativeRecoveryBlocked:
            ("权限或任务状态不允许，请打开会话处理提示", "Permissions or task state stopped it; open the chat.")
        case .nativeRecoveryRuntimeUnavailable:
            ("会话在新账号上没有报到，请打开原会话看看", "The chat hasn't reported on the new account; open it.")
        case .nativeRecoveryExpired:
            ("接续请求已过期，请打开会话确认是否继续", "The continuation expired; open the chat to decide.")
        case .nativeRecoveryConversationUnavailable:
            ("未能打开原会话，请在新账号上手动打开", "Couldn't open the chat; open it on the new account.")
        case .nativeRecoveryExecutionFailed:
            ("续跑未成功，请查看会话里的错误", "The continuation failed; check the error in the chat.")
        case .nativeRecoveryIncomplete:
            ("接续没有完成，请打开原会话核对", "The continuation didn't finish; check the chat.")
        case .openRecoveryRecords: ("查看本地记录", "View local records")
        case .warningSessions:
            ("有 {n} 个会话没能同步", "{n} sessions didn't sync")
        case .clauseBackup:
            ("备份没有成功", "Backup failed")
        case .clauseContinuity:
            ("没能记下当前对话", "This chat wasn't saved")
        case .clauseOrganization:
            ("组织未能确认", "Organization unknown")
        case .clauseConversation:
            ("没能打开刚才的对话", "The last chat didn't reopen")
        case .clauseNotCompacted:
            ("对话没能先压缩", "The chat wasn't compacted first")
        case .switchFailed:
            ("切换失败：{reason}", "Switch failed: {reason}")
        case .failedToCloseClaude:
            ("没能关闭 Claude", "Couldn't quit Claude")
        case .failedToOpenClaude:
            ("没能打开 Claude", "Couldn't open Claude")
        case .failedAdd:
            ("添加失败：{reason}", "Add failed: {reason}")
        case .failedRemove:
            ("移除失败：{reason}", "Remove failed: {reason}")
        case .failedAutoCorrect:
            ("自动切回失败：{reason}", "Auto-switch failed: {reason}")
        case .failedHistoryImport:
            ("导入失败：{reason}", "Import failed: {reason}")
        case .reasonCouldNotReadProcesses:
            ("无法读取进程", "Can't read processes")
        case .reasonTargetMissing:
            ("账号不存在", "Account is missing")
        case .reasonTargetUnreadable:
            ("账号无法读取", "Account can't be read")
        case .reasonOperationInFlight:
            ("已有操作在进行", "Something is already running")
        case .reasonRefusedActive:
            ("不能移除当前账号", "Can't remove the current one")
        case .reasonRefusedLast:
            ("至少留一个账号", "Keep at least one account")
        case .reasonRefusedRunning:
            ("Claude 正在使用它", "Claude is using it")
        case .reasonRunningUnknown:
            ("无法确认是否在运行", "Running state is unknown")
        case .reasonSignedInDiffers:
            ("登录的账号不同", "That was a different account")
        case .reasonCancelled:
            ("已取消", "Cancelled")
        case .returnedToPreviousAccount:
            ("所选账号没能打开，已回到上一个账号", "Couldn't open it; back on the previous account")
        case .transferFailedReturnedToPreviousAccount:
            ("会话转移失败，已回到原账号\n请打开原会话确认任务状态",
             "Chat transfer failed.\nBack on the original account.\nCheck the work in the original chat.")
        case .transferFailedNotReopened:
            ("会话转移失败，原账号也没能打开\n请手动打开 Claude 确认任务状态",
             "Chat transfer failed.\nThe original account didn't reopen.\nOpen Claude to check the work.")
        case .addedAccount:
            ("已添加 {name}", "Added {name}")
        case .added:
            ("已添加", "Added")
        case .removedAccount:
            ("已移除 {name}", "Removed {name}")
        case .removed:
            ("已移除", "Removed")
        case .removedPartial:
            ("已移除 {name}，清理未完成", "Removed {name}, cleanup unfinished")
        case .removedCleanup:
            ("已移除，清理未完成", "Removed, but cleanup didn't finish")
        case .cleanupUnfinished:
            ("清理没有完成", "Cleanup didn't finish")
        case .removingAccount:
            ("正在移除…", "Removing…")
        case .switchingBack:
            ("正在切回…", "Switching back…")
        case .retry:
            ("重试", "Retry")
        case .dismissNotice:
            ("知道了", "Got it")
        case .taskGuardTitle:
            ("有 Code 任务正在运行", "A Code task is running")
        case .taskGuardBody:
            ("切到 {name} 会关闭 Claude，\n正在运行的任务会中断。", "Switching to {name} quits Claude.\nRunning tasks are interrupted.")
        case .taskGuardWait:
            ("等任务结束后切换", "Switch when tasks finish")
        case .taskGuardSwitchNow:
            ("立即切换", "Switch now")
        case .compactFirstTitle:
            ("先压缩当前对话", "Compacting the chat first")
        case .compactFirstBody:
            ("这段对话很长，先在当前账号上压缩好，\n再切到 {name}，新账号能省下大部分额度。",
             "This chat is long. Compacting it on this account\nfirst saves most of {name}'s usage for it.")
        case .compactFirstWaiting:
            ("正在压缩，约需 1–3 分钟…", "Compacting, about 1–3 minutes…")
        case .compactFirstSkip:
            ("跳过，直接切换", "Skip and switch now")
        case .taskGuardCount:
            ("{n} 个 Code 任务正在运行", "Code tasks running: {n}")
        case .taskGuardUnknown:
            ("无法确认有没有 Code 任务在运行", "Couldn't tell if a Code task is running")
        case .cancel:
            ("取消", "Cancel")
        case .waitingForTasks:
            ("正在等待任务结束…", "Waiting for tasks to finish…")
        case .waitingForSignIn:
            ("等待登录…", "Waiting for sign-in…")
        case .cancelAdd:
            ("取消添加", "Cancel adding")
        case .importingHistory:
            ("正在导入历史会话…", "Importing your\nconversations…")
        case .closingClaude:
            ("正在关闭 Claude…", "Quitting Claude…")
        case .openingClaude:
            ("正在打开 Claude…", "Opening Claude…")
        case .duplicateAccount:
            ("这个账号已经在列表里了（{name}）", "This account is already in the list ({name})")
        case .duplicateNote:
            ("与 {name} 是同一个账号", "Same account as {name}")
        case .keepBoth:
            ("保留两个", "Keep both")
        case .discardNew:
            ("放弃新添加的", "Discard the new one")
        case .rename:
            ("改名", "Rename")
        case .refreshQuota:
            ("刷新额度", "Refresh quota")
        case .hudQuotaUpdated:
            ("额度已更新", "Quota updated")
        case .hudQuotaPartlyUpdated:
            ("已更新 {updated}/{requested} 个账号额度", "Quota updated: {updated}/{requested} accounts")
        case .hudQuotaFailed:
            ("额度未更新，请重试", "Couldn't refresh quota")
        case .hudQuotaNoAccounts:
            ("没有可刷新的账号", "No accounts to refresh")
        case .hudVersionCopied:
            ("已复制版本号", "Version copied")
        case .hudBackupsOpened:
            ("已在访达中打开备份文件夹", "Backups folder opened in Finder")
        case .hudBackupsFailed:
            ("未能打开备份文件夹", "Couldn't open backups folder")
        case .hudRecoveryOpened:
            ("已在访达中打开接续记录", "Recovery records opened in Finder")
        case .hudRecoveryFailed:
            ("未能打开接续记录", "Couldn't open recovery records")
        case .remove:
            ("移除", "Remove")
        case .removeConfirmTitle:
            ("移除 {name}？", "Remove {name}?")
        case .removeConfirmBody:
            ("账号文件夹会移到归档文件夹，不会删除。", "The account folder is archived, not deleted.")
        case .nameEmpty:
            ("名称不能为空", "Name can't be empty")
        case .nameTooLong:
            ("名称最多 20 个字", "At most 20 characters")
        case .autoCorrected:
            ("Claude 打开的是默认账号，已切回 {name}", "Claude opened the default account\nand switched back to {name}.")
        case .autoCorrectPaused:
            ("Claude 反复打开默认账号，自动切回已暂停 10 分钟", "Claude keeps opening the default account.\nAuto-switch is paused for 10 minutes.")
        case .autoCompacted:
            ("已在额度用完前压缩对话：约 {before} 万 → {after} 万", "Compacted a chat before the limit:\n~{before}k → {after}k tokens.")
        case .autoCompactedSize:
            ("已在额度用完前压缩一段约 {before} 万的对话", "Compacted a ~{before}k-token chat\nbefore the limit.")
        case .autoCompactedResumed:
            ("额度快用完：已暂停任务并压缩对话（约 {before} 万），\n任务已自动继续", "Near the limit: paused the task, compacted\nthe chat (~{before}k tokens) and resumed.")
        case .autoCompactedNotResumed:
            ("额度快用完：已暂停任务并压缩对话（约 {before} 万），\n但任务没能自动继续，请让它接着做",
             "Near the limit: paused the task, compacted\nthe chat (~{before}k tokens). Ask it to go on.")
        case .autoCompactNotResumed:
            ("额度快用完：任务已暂停，没能自动继续，\n请让它接着做", "Near the limit, the task paused and did not\ngo on. Ask it to go on.")
        case .autoCompactFailedNotResumed:
            ("额度快用完：任务已暂停，没能自动继续，\n请发送 /compact，再让它接着做",
             "Near the limit, the task paused and did not\ngo on. Send /compact, then ask it to go on.")
        case .autoCompactedBeforeSwitch:
            ("切换前已压缩对话：约 {before} 万 → {after} 万", "Compacted the chat before switching:\n~{before}k → {after}k tokens.")
        case .autoCompactedBeforeSwitchSize:
            ("切换前已压缩一段约 {before} 万的对话", "Compacted a ~{before}k-token chat\nbefore switching.")
        case .autoCompactFailed:
            ("额度快用完，自动压缩没有成功，\n请在对话里发送 /compact", "Near the limit, auto-compaction failed.\nSend /compact in the chat.")
        case .foundAccount:
            ("发现账号 {name}", "Found account {name}")
        case .addFound:
            ("添加", "Add")
        case .dismissFound:
            ("忽略", "Dismiss")
        case .historyImportInterrupted:
            ("导入已中断：{name}", "Import paused: {name}")
        case .historyImportFailed:
            ("导入失败：{name}", "Import failed: {name}")
        case .historyImportUnavailable:
            ("暂时无法导入：{name}", "Import unavailable: {name}")
        case .settings:
            ("设置", "Settings")
        case .launchAtLogin:
            ("开机自启", "Launch at login")
        case .autoSync:
            ("自动同步", "Auto-sync")
        case .autoCompact:
            ("自动压缩", "Auto-compact")
        case .autoCompactPluginLive:
            ("压缩插件已连接", "Compaction plugin connected")
        case .autoCompactPluginLastSeen:
            ("压缩插件上次报到 {time}", "Compaction plugin last reported {time}")
        case .autoCompactPluginNone:
            ("还没收到压缩插件的报到", "No report from the plugin yet")
        case .language:
            ("语言", "Language")
        case .languageSystem:
            ("跟随系统", "Follow system")
        case .languageZhHans:
            ("简体中文", "简体中文")
        case .languageEnglish:
            ("English", "English")
        case .openBackups:
            ("打开备份文件夹", "Open Backups folder")
        case .ignoredAccounts:
            ("已忽略的账号", "Dismissed accounts")
        case .addBack:
            ("重新添加", "Add back")
        case .quitApp:
            ("退出 CC-Relay", "Quit CC-Relay")
        case .version:
            ("版本 {version}", "Version {version}")
        case .back:
            ("返回", "Back")
        case .resetTooltip:
            ("将于 {year}年{month}月{day}日 {weekday} {time} 重置", "Resets on {weekday}, {month} {day}, {year} at {time}")
        case .settingsAppearance:
            ("外观", "Appearance")
        case .appearanceSystem:
            ("跟随系统", "System")
        case .appearanceLight:
            ("浅色", "Light")
        case .appearanceDark:
            ("深色", "Dark")
        case .settingsGeneral:
            ("通用", "General")
        case .launchAtLoginDetail:
            ("登录 Mac 后自动打开 CC-Relay", "Opens CC-Relay when you log in")
        case .settingsSwitching:
            ("切换", "Switching")
        case .autoSwitch:
            ("自动切换", "Auto-switch")
        case .autoSwitchDetail:
            ("额度耗尽或限流时自动换号续跑", "On quota or rate limits,\nswitches accounts and resumes work.")
        case .autoSwitchNoAccount:
            ("额度已用完，暂时没有可用账号\n原任务已保留，稍后自动重试", "Quota is exhausted; no account is ready.\nThe work is kept; checking again shortly.")
        case .autoSwitchNoAccountUntil:
            ("额度已用完，暂时没有可用账号\n原任务已保留，{time} 后自动重试", "Quota is exhausted; no account is ready.\nThe work is kept; trying again after {time}.")
        case .autoSwitchNoOtherSignIn:
            ("额度已用完，其他账号都没登录\n原任务已保留，登录后自动重试", "Quota is exhausted; no other account is signed in.\nThe work is kept; sign one in to try again.")
        case .autoSwitchCommandRunning:
            ("有命令正在运行，切换会中断它\n等它结束后再自动切换", "A running command would be cut off.\nSwitching waits until it ends.")
        case .autoSwitchLimitRepeated:
            ("刚换过号又遇到限流，先不再换\n额度还有余量，过一会儿回到会话继续", "Rate-limited again right after a switch.\nQuota is left; go back to the chat in a while.")
        case .autoSwitchAccountRestricted:
            ("这个账号被暂停或不允许使用\n自动切换已停下，请到 claude.ai 查看", "This account is on hold or not allowed.\nAuto-switch stopped; check it on claude.ai.")
        case .autoSwitchNotReady:
            ("没能准备好接续\n先保留当前账号", "The work couldn't be readied to carry over.\nStaying on this account.")
        case .autoSwitchNotReadyUntil:
            ("没能准备好接续\n{time} 后再试", "The work couldn't be readied to carry over.\nTrying again after {time}.")
        case .autoSwitchOtherAccounts:
            ("其他账号的 Claude 仍开着\n关闭其他账号后会自动重试", "Other Claude accounts are still open.\nClose them to allow automatic switching.")
        case .pluginUpdateFailed:
            ("插件没能更新", "The plugin couldn't be updated")
        case .autoSwitchLastFailed:
            ("上次自动切换没能转移会话\n额度恢复前不再自动重试", "The last auto-switch couldn't move the chat.\nNo automatic retry until the limit resets.")
        case .autoSwitchNeedsBypass:
            ("能用的账号都没开“跳过权限确认”\n手动切换到 {name}，在那里打开", "No account with quota left skips permission prompts.\nSwitch to {name} by hand and turn it on there.")
        case .reasonContinuationUnavailable:
            ("原任务续跑尚未就绪", "continuation is not ready")
        case .reasonTargetCannotContinue:
            ("这个账号没开“跳过权限确认”", "It doesn't skip permissions")
        case .autoSyncDetail:
            ("切换前先备份，再同步两个账号的对话记录", "Backs up first, then syncs\nboth accounts\u{2019} conversations")
        case .settingsCompaction:
            ("压缩", "Compaction")
        case .autoCompactDetail:
            ("额度快用完时，先把很长的对话压缩", "Compacts long conversations\nwhen quota runs low")
        case .pluginNeededForAutoSwitch:
            ("自动切换要用 CC-Relay 插件", "Auto-switch needs the CC-Relay plugin")
        case .pluginNeededForAutoCompact:
            ("自动压缩要用 CC-Relay 插件", "Auto-compact needs the CC-Relay plugin")
        case .pluginNeededBody:
            ("插件会装进 Claude Code，\n并打开它需要的一项设置，改之前先备份",
             "It goes into Claude Code, with one setting\nit needs turned on; a backup comes first.")
        case .installAndTurnOn:
            ("安装并开启", "Install and turn on")
        case .pluginInstalling:
            ("正在安装插件…", "Installing the plugin…")
        case .pluginInstallingBody:
            ("装进 Claude Code，并打开它需要的设置", "Into Claude Code, with the setting it needs")
        case .autoSwitchTurnedOn:
            ("已开启自动切换", "Auto-switch is on")
        case .autoCompactTurnedOn:
            ("已开启自动压缩", "Auto-compact is on")
        case .pluginReloadConversations:
            ("开着的会话重新加载一次，就能用上插件", "Reload open conversations once to use it.")
        case .pluginNotInstalled:
            ("插件没装上", "The plugin wasn't installed")
        case .pluginInstalledFeatureOff:
            ("插件已装好", "The plugin is installed")
        case .autoSwitchNotTurnedOn:
            ("但自动切换这次没打开\n等当前操作结束后再打开一次", "Auto-switch didn't turn on this time.\nTurn it on again once the current step ends.")
        case .autoCompactNotTurnedOn:
            ("但自动压缩这次没打开\n等当前操作结束后再打开一次", "Auto-compact didn't turn on this time.\nTurn it on again once the current step ends.")
        case .pluginClaudeCodeMissing:
            ("没找到 Claude Code\n先在 Claude 里打开一次 Code 再试", "Claude Code wasn't found.\nOpen Code in Claude once, then try again.")
        case .pluginSettingsUnusable:
            ("Claude Code 的设置文件用不了\n先检查 ~/.claude/settings.json",
             "Claude Code's settings file can't be used.\nCheck ~/.claude/settings.json first.")
        case .pluginNotFinished:
            ("安装没有完成，稍后再试", "The install didn't finish. Try again later.")
        case .autoCompactOff:
            ("已关闭，不会自动压缩", "Off, nothing is compacted")
        case .settingsOther:
            ("其他", "Other")
        case .openBackupsDetail:
            ("每个账号保留最近 5 份备份", "The last 5 backups of each account")
        case .quitConfirmBody:
            ("退出后额度不再刷新，也不会自动切换账号。", "After quitting, quotas no longer refresh\nand accounts are not switched automatically.")
        case .quitConfirm:
            ("退出", "Quit")
        case .confirmSwitch:
            ("切换确认", "Confirm switches")
        case .confirmSwitchDetail:
            ("点账号切换前先问一次；\n自动切换不会询问", "Asks before a switch you click;\nauto-switch never asks")
        case .switchAskTitle:
            ("切换到 {name}？", "Switch to {name}?")
        case .switchAskBody:
            ("Claude 会关闭并用 {name} 重新打开，\n刚才的对话会自动打开", "Claude quits and reopens as {name};\nyour last chat reopens too")
        case .switchAction:
            ("切换", "Switch")
        case .dontAskAgain:
            ("以后不再询问", "Don't ask again")
        case .dontAskAgainHint:
            ("可以在 设置 › 切换确认 里改回来", "Turn it back on in Settings › Confirm switches")
        case .switchFailedTitle:
            ("没能切换到 {name}", "Couldn't switch to {name}")
        case .switchFailedBack:
            ("{name} 没能打开，已回到 {previous}。", "{name} didn't open; back on {previous}.")
        case .close:
            ("关闭", "Close")
        case .addSignInTitle:
            ("在弹出的 Claude 窗口里登录新账号", "Sign in with the new account\nin the Claude window")
        case .addSignInBody:
            ("登录后自动添加，并导入其他账号的历史会话", "It's added once you sign in, with your\nother accounts' conversations")
        case .addImportingBody:
            ("把其他账号的历史会话导入新账号", "Copying your other accounts' conversations")
        case .addFailedTitle:
            ("没能添加账号", "Couldn't add the account")
        case .emptySeatTitle:
            ("还没有可以切换的账号", "No other account yet")
        case .emptySeatBody:
            ("再添加一个账号，额度用完时就能切过去", "Add one to switch to when quota runs out")
        case .undo:
            ("撤销", "Undo")
        case .restoredAccount:
            ("已恢复 {name}", "{name} is back")
        case .menuRemoveCurrent:
            ("正在使用的账号不能移除", "The account in use stays")
        case .moreActions:
            ("{name} 的更多操作", "More for {name}")
        case .renameTitle:
            ("给 {name} 改名", "Rename {name}")
        case .save:
            ("保存", "Save")
        case .newName:
            ("新名称", "New name")
        }
    }
}

enum L10nSubstituting {
    static func apply(_ template: String, parameters: [String: String]) -> String {
        var result = ""
        var index = template.startIndex
        while index < template.endIndex {
            if template[index] == "{",
               let end = template[index...].firstIndex(of: "}"),
               template.index(after: index) < end {
                let name = String(template[template.index(after: index)..<end])
                if isParameterName(name) {
                    result.append(parameters[name] ?? "{\(name)}")
                    index = template.index(after: end)
                    continue
                }
            }
            result.append(template[index])
            index = template.index(after: index)
        }
        return result
    }

    static func parameterNames(in template: String) -> [String] {
        var names: [String] = []
        var index = template.startIndex
        while index < template.endIndex {
            if template[index] == "{",
               let end = template[index...].firstIndex(of: "}"),
               template.index(after: index) < end {
                let name = String(template[template.index(after: index)..<end])
                if isParameterName(name) {
                    names.append(name)
                    index = template.index(after: end)
                    continue
                }
            }
            index = template.index(after: index)
        }
        return names
    }

    private static func isParameterName(_ name: String) -> Bool {
        !name.isEmpty && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }
}

private struct L10nLanguageKey: EnvironmentKey {
    static let defaultValue = L10nLanguage.resolve(preferredLanguages: Locale.preferredLanguages)
}

extension EnvironmentValues {
    public var l10nLanguage: L10nLanguage {
        get { self[L10nLanguageKey.self] }
        set { self[L10nLanguageKey.self] = newValue }
    }
}
