import SwiftUI

@main
struct GmailReaderIOSApp: App {
    @StateObject private var accounts: AccountStore
    @StateObject private var mailbox: MailboxViewModel

    init() {
        let accountStore = AccountStore()
        let service = MailCoreService()
        _accounts = StateObject(wrappedValue: accountStore)
        _mailbox = StateObject(wrappedValue: MailboxViewModel(accounts: accountStore, service: service))
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(accounts)
                .environmentObject(mailbox)
                .onAppear { mailbox.reload() }
        }
    }
}
