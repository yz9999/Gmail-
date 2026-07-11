import SwiftUI

@main
struct GmailReaderApp: App {
    @StateObject private var accounts: AccountStore
    @StateObject private var preferences: AppPreferences
    @StateObject private var mailbox: MailboxViewModel

    init() {
        let accountStore = AccountStore()
        let appPreferences = AppPreferences()
        _accounts = StateObject(wrappedValue: accountStore)
        _preferences = StateObject(wrappedValue: appPreferences)
        _mailbox = StateObject(wrappedValue: MailboxViewModel(accounts: accountStore, preferences: appPreferences))
    }

    var body: some Scene {
        WindowGroup("Gmail") {
            RootView()
                .environmentObject(accounts)
                .environmentObject(preferences)
                .environmentObject(mailbox)
                .frame(minWidth: 900, minHeight: 600)
                .onAppear { mailbox.reload() }
        }
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("写邮件") { mailbox.showingCompose = true }.keyboardShortcut("n", modifiers: [.command])
            }
            CommandMenu("邮件") {
                Button("刷新") { mailbox.reload() }.keyboardShortcut("r", modifiers: [.command])
                Button("将所有会话标记为已读") { mailbox.markAllRead() }
            }
        }
    }
}
