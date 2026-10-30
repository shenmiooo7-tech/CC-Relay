import Foundation

@MainActor
public struct PanelActions {
    public var selectAccount: (String) -> Void
    public var beginRename: (String) -> Void
    public var rename: (String, String) -> Void
    public var cancelRename: (String) -> Void
    public var remove: (String) -> Void
    public var confirmRemove: () -> Void
    public var addAccount: () -> Void
    public var cancelAdd: () -> Void
    public var keepBothAccounts: () -> Void
    public var discardNewAccount: () -> Void
    public var waitForTasks: () -> Void
    public var switchNow: () -> Void
    public var cancelTaskGuard: () -> Void
    public var skipCompaction: () -> Void
    public var bannerAction: (String) -> Void
    public var bannerSecondaryAction: (String) -> Void
    public var openSettings: () -> Void
    public var closeSettings: () -> Void
    public var setLaunchAtLogin: (Bool) -> Void
    public var setAutoSync: (Bool) -> Void
    public var setAutoSwitch: (Bool) -> Void
    public var setAutoCompact: (Bool) -> Void
    public var setLanguage: (LanguageChoice) -> Void
    public var openBackups: () -> Void
    public var dismissSheet: () -> Void
    public var quit: () -> Void
    public var refreshQuota: (String) -> Void
    /// The header's button: every signed-in account's quota.
    public var refreshAllQuotas: () -> Void
    /// Puts a notice's dialog away for now.
    public var closeNotice: (String) -> Void
    public var setAppearance: (AppearanceChoice) -> Void
    /// Copies the version line for a bug report.
    public var copyVersion: () -> Void
    public var dismissResult: () -> Void
    public var addIgnoredAccount: (String) -> Void
    /// The switch question's answers: switch (and maybe stop asking), or not now.
    public var confirmSwitch: (_ stopAsking: Bool) -> Void
    public var cancelSwitchQuestion: () -> Void
    /// After a switch that failed: try it again, or close its dialog.
    public var retrySwitch: () -> Void
    public var closeSwitchResult: () -> Void
    /// After an account that could not be added: try again, or close its dialog.
    public var retryAdd: () -> Void
    public var closeAddResult: () -> Void
    public var setConfirmSwitch: (Bool) -> Void
    /// The button in the line in the middle of the panel: undo what it confirms.
    public var hudAction: () -> Void
    /// The plugin's dialog: install it and turn the feature on, or close the dialog.
    public var installPlugin: () -> Void
    public var closePluginDialog: () -> Void
    /// The retry in the row a failed plugin update leaves in Settings.
    public var retryPluginUpdate: () -> Void

    public init(
        selectAccount: @escaping (String) -> Void,
        beginRename: @escaping (String) -> Void,
        rename: @escaping (String, String) -> Void,
        cancelRename: @escaping (String) -> Void,
        remove: @escaping (String) -> Void,
        confirmRemove: @escaping () -> Void,
        addAccount: @escaping () -> Void,
        cancelAdd: @escaping () -> Void,
        keepBothAccounts: @escaping () -> Void,
        discardNewAccount: @escaping () -> Void,
        waitForTasks: @escaping () -> Void,
        switchNow: @escaping () -> Void,
        cancelTaskGuard: @escaping () -> Void,
        bannerAction: @escaping (String) -> Void,
        bannerSecondaryAction: @escaping (String) -> Void,
        openSettings: @escaping () -> Void,
        closeSettings: @escaping () -> Void,
        setLaunchAtLogin: @escaping (Bool) -> Void,
        setAutoSync: @escaping (Bool) -> Void,
        setAutoCompact: @escaping (Bool) -> Void,
        setLanguage: @escaping (LanguageChoice) -> Void,
        openBackups: @escaping () -> Void,
        dismissSheet: @escaping () -> Void,
        quit: @escaping () -> Void,
        refreshQuota: @escaping (String) -> Void,
        dismissResult: @escaping () -> Void,
        addIgnoredAccount: @escaping (String) -> Void,
        skipCompaction: @escaping () -> Void,
        refreshAllQuotas: @escaping () -> Void = {},
        closeNotice: @escaping (String) -> Void = { _ in },
        setAppearance: @escaping (AppearanceChoice) -> Void = { _ in },
        copyVersion: @escaping () -> Void = {},
        confirmSwitch: @escaping (Bool) -> Void = { _ in },
        cancelSwitchQuestion: @escaping () -> Void = {},
        retrySwitch: @escaping () -> Void = {},
        closeSwitchResult: @escaping () -> Void = {},
        retryAdd: @escaping () -> Void = {},
        closeAddResult: @escaping () -> Void = {},
        setConfirmSwitch: @escaping (Bool) -> Void = { _ in },
        hudAction: @escaping () -> Void = {},
        setAutoSwitch: @escaping (Bool) -> Void = { _ in },
        installPlugin: @escaping () -> Void = {},
        closePluginDialog: @escaping () -> Void = {},
        retryPluginUpdate: @escaping () -> Void = {}
    ) {
        self.selectAccount = selectAccount
        self.beginRename = beginRename
        self.rename = rename
        self.cancelRename = cancelRename
        self.remove = remove
        self.confirmRemove = confirmRemove
        self.addAccount = addAccount
        self.cancelAdd = cancelAdd
        self.keepBothAccounts = keepBothAccounts
        self.discardNewAccount = discardNewAccount
        self.waitForTasks = waitForTasks
        self.switchNow = switchNow
        self.cancelTaskGuard = cancelTaskGuard
        self.skipCompaction = skipCompaction
        self.bannerAction = bannerAction
        self.bannerSecondaryAction = bannerSecondaryAction
        self.openSettings = openSettings
        self.closeSettings = closeSettings
        self.setLaunchAtLogin = setLaunchAtLogin
        self.setAutoSync = setAutoSync
        self.setAutoSwitch = setAutoSwitch
        self.setAutoCompact = setAutoCompact
        self.setLanguage = setLanguage
        self.openBackups = openBackups
        self.dismissSheet = dismissSheet
        self.quit = quit
        self.refreshQuota = refreshQuota
        self.refreshAllQuotas = refreshAllQuotas
        self.closeNotice = closeNotice
        self.setAppearance = setAppearance
        self.copyVersion = copyVersion
        self.dismissResult = dismissResult
        self.addIgnoredAccount = addIgnoredAccount
        self.confirmSwitch = confirmSwitch
        self.cancelSwitchQuestion = cancelSwitchQuestion
        self.retrySwitch = retrySwitch
        self.closeSwitchResult = closeSwitchResult
        self.retryAdd = retryAdd
        self.closeAddResult = closeAddResult
        self.setConfirmSwitch = setConfirmSwitch
        self.hudAction = hudAction
        self.installPlugin = installPlugin
        self.closePluginDialog = closePluginDialog
        self.retryPluginUpdate = retryPluginUpdate
    }

    public static var noop: PanelActions {
        PanelActions(
            selectAccount: { _ in },
            beginRename: { _ in },
            rename: { _, _ in },
            cancelRename: { _ in },
            remove: { _ in },
            confirmRemove: {},
            addAccount: {},
            cancelAdd: {},
            keepBothAccounts: {},
            discardNewAccount: {},
            waitForTasks: {},
            switchNow: {},
            cancelTaskGuard: {},
            bannerAction: { _ in },
            bannerSecondaryAction: { _ in },
            openSettings: {},
            closeSettings: {},
            setLaunchAtLogin: { _ in },
            setAutoSync: { _ in },
            setAutoCompact: { _ in },
            setLanguage: { _ in },
            openBackups: {},
            dismissSheet: {},
            quit: {},
            refreshQuota: { _ in },
            dismissResult: {},
            addIgnoredAccount: { _ in },
            skipCompaction: {}
        )
    }
}
