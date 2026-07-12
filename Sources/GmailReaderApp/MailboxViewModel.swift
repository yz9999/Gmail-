import Foundation

@MainActor
final class MailboxViewModel: ObservableObject {
    @Published var mailbox: MailboxKind = .inbox
    @Published var messages: [MailSummary] = []
    @Published var selectedMessage: MailMessage?
    @Published var searchText = ""
    @Published private(set) var activeSearch = ""
    @Published var page = 1
    @Published var total = 0
    @Published var isLoading = false
    @Published var isLoadingMessage = false
    @Published var isTranslating = false
    @Published var translatedBody: String?
    @Published var translatedHTML: String?
    @Published var showingTranslation = false
    @Published var errorMessage: String?
    @Published var toastMessage: String?
    @Published var showingCompose = false
    @Published var showingAccounts = false
    @Published var showingSettings = false

    let pageSize = 50
    private let service = GmailService()
    private let translationService = MailTranslationService()
    private unowned let accounts: AccountStore
    private unowned let preferences: AppPreferences
    private var listTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var translationTask: Task<Void, Never>?
    private var generation = UUID()
    private var detailRequestID = UUID()

    init(accounts: AccountStore, preferences: AppPreferences) {
        self.accounts = accounts
        self.preferences = preferences
    }

    var pageCount: Int { max(1, Int(ceil(Double(total) / Double(pageSize)))) }
    var hasTranslation: Bool { translatedBody != nil || translatedHTML != nil }
    var rangeText: String {
        guard total > 0 else { return "0 封" }
        let start = (page - 1) * pageSize + 1
        let end = min(page * pageSize, total)
        return "\(start)–\(end)，共 \(total) 封"
    }

    func accountChanged() {
        generation = UUID()
        detailRequestID = UUID()
        listTask?.cancel(); detailTask?.cancel(); translationTask?.cancel()
        selectedMessage = nil
        resetTranslation()
        page = 1
        activeSearch = ""
        searchText = ""
        reload()
    }

    func selectMailbox(_ value: MailboxKind) {
        guard mailbox != value || !activeSearch.isEmpty else { return }
        mailbox = value
        activeSearch = ""
        searchText = ""
        page = 1
        selectedMessage = nil
        reload()
    }

    func submitSearch() {
        activeSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        page = 1
        selectedMessage = nil
        reload()
    }

    func clearSearch() {
        searchText = ""
        activeSearch = ""
        page = 1
        selectedMessage = nil
        reload()
    }

    func previousPage() {
        guard page > 1 else { return }
        page -= 1; selectedMessage = nil; reload()
    }

    func nextPage() {
        guard page < pageCount else { return }
        page += 1; selectedMessage = nil; reload()
    }

    func refresh() {
        reload(forceRefresh: true)
    }

    func reload(forceRefresh: Bool = false) {
        listTask?.cancel()
        guard let account = accounts.selectedAccount else {
            messages = []; total = 0; isLoading = false
            return
        }
        let requestGeneration = generation
        let requestedPage = page
        let requestedMailbox = mailbox
        let requestedQuery = activeSearch
        isLoading = true
        errorMessage = nil
        listTask = Task {
            do {
                let credentials = try makeCredentials(account)
                let result = try await service.page(kind: requestedMailbox, page: requestedPage, pageSize: pageSize,
                                                    query: requestedQuery.isEmpty ? nil : requestedQuery,
                                                    forceRefresh: forceRefresh, credentials: credentials)
                try Task.checkCancellation()
                guard requestGeneration == generation, accounts.selectedAccountID == account.id,
                      requestedMailbox == mailbox, requestedPage == page, requestedQuery == activeSearch else { return }
                messages = result.messages
                total = result.total
                if page > pageCount { page = pageCount; reload(); return }
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, requestGeneration == generation, accounts.selectedAccountID == account.id,
                      requestedMailbox == mailbox, requestedPage == page, requestedQuery == activeSearch else { return }
                errorMessage = error.localizedDescription
            }
            if requestGeneration == generation { isLoading = false }
        }
    }

    func open(_ summary: MailSummary) {
        detailTask?.cancel()
        translationTask?.cancel()
        guard let account = accounts.selectedAccount else { return }
        let requestGeneration = generation
        let requestID = UUID()
        detailRequestID = requestID
        isLoadingMessage = true
        selectedMessage = nil
        resetTranslation()
        if !summary.isRead {
            if let index = messages.firstIndex(where: { $0.uid == summary.uid }) { messages[index].isRead = true }
        }
        detailTask = Task {
            do {
                let credentials = try makeCredentials(account)
                if !summary.isRead {
                    try await service.setFlag(uid: summary.uid, kind: mailbox, query: activeSearch, flag: "\\Seen", enabled: true,
                                              credentials: credentials)
                }
                let message = try await service.message(uid: summary.uid, kind: mailbox, query: activeSearch, credentials: credentials)
                try Task.checkCancellation()
                guard requestGeneration == generation, accounts.selectedAccountID == account.id else { return }
                selectedMessage = message
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, requestGeneration == generation, requestID == detailRequestID,
                      accounts.selectedAccountID == account.id else { return }
                errorMessage = error.localizedDescription
            }
            if requestGeneration == generation { isLoadingMessage = false }
        }
    }

    func closeMessage() {
        detailTask?.cancel()
        translationTask?.cancel()
        detailRequestID = UUID()
        selectedMessage = nil
        isLoadingMessage = false
        resetTranslation()
    }

    func translateCurrentMessage() {
        guard let message = selectedMessage, let account = accounts.selectedAccount else { return }
        if hasTranslation {
            showingTranslation = true
            return
        }
        translationTask?.cancel()
        let requestID = detailRequestID
        let cacheKey = "\(account.id.uuidString)|\(message.messageID)|\(message.uid)"
        isTranslating = true
        translationTask = Task {
            do {
                let translated = try await translationService.translateToChinese(
                    plainBody: message.plainBody,
                    htmlBody: message.htmlBody,
                    cacheKey: cacheKey,
                    proxy: preferences.proxy
                )
                try Task.checkCancellation()
                guard requestID == detailRequestID, selectedMessage?.uid == message.uid else { return }
                if translated.isHTML {
                    translatedHTML = translated.content
                } else {
                    translatedBody = translated.content
                }
                showingTranslation = true
            } catch is CancellationError {
                return
            } catch {
                guard requestID == detailRequestID else { return }
                errorMessage = error.localizedDescription
            }
            if requestID == detailRequestID { isTranslating = false }
        }
    }

    func showOriginalMessage() {
        showingTranslation = false
    }

    func showTranslatedMessage() {
        guard hasTranslation else { translateCurrentMessage(); return }
        showingTranslation = true
    }

    func toggleStar(uid: UInt64) {
        guard let account = accounts.selectedAccount else { return }
        let current = messages.first(where: { $0.uid == uid })?.isStarred ?? selectedMessage?.isStarred ?? false
        if let index = messages.firstIndex(where: { $0.uid == uid }) { messages[index].isStarred.toggle() }
        if selectedMessage?.uid == uid { selectedMessage?.isStarred.toggle() }
        Task {
            do {
                try await service.setFlag(uid: uid, kind: mailbox, query: activeSearch, flag: "\\Flagged", enabled: !current,
                                          credentials: try makeCredentials(account))
            } catch {
                if let index = messages.firstIndex(where: { $0.uid == uid }) { messages[index].isStarred = current }
                if selectedMessage?.uid == uid { selectedMessage?.isStarred = current }
                errorMessage = error.localizedDescription
            }
        }
    }

    func markUnread(_ message: MailMessage) {
        guard let account = accounts.selectedAccount else { return }
        closeMessage()
        if let index = messages.firstIndex(where: { $0.uid == message.uid }) { messages[index].isRead = false }
        Task {
            do {
                try await service.setFlag(uid: message.uid, kind: mailbox, query: activeSearch, flag: "\\Seen", enabled: false,
                                          credentials: try makeCredentials(account))
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func markAllRead() {
        guard let account = accounts.selectedAccount else { return }
        Task {
            do {
                let count = try await service.markAllRead(kind: mailbox, query: activeSearch,
                                                          credentials: try makeCredentials(account))
                for index in messages.indices { messages[index].isRead = true }
                toast("已将 \(count) 封邮件标记为已读")
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func send(recipients: [String], subject: String, body: String) async -> Bool {
        guard let account = accounts.selectedAccount else { return false }
        do {
            try await service.send(to: recipients, subject: subject, body: body, credentials: try makeCredentials(account))
            toast("邮件已发送")
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func verifyAndAdd(name: String, address: String, password: String) async -> Bool {
        let normalized = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let compactPassword = password.filter { !$0.isWhitespace }
        do {
            guard normalized.contains("@"), compactPassword.count >= 16 else {
                throw GmailReaderError.configuration("请输入有效邮箱地址和 16 位应用专用密码")
            }
            let credentials = GmailCredentials(address: normalized, password: compactPassword, proxy: preferences.proxy)
            try await service.verify(credentials: credentials)
            _ = try accounts.add(name: name, address: normalized, appPassword: compactPassword)
            accountChanged()
            toast("账号已安全保存到 macOS 钥匙串")
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func makeCredentials(_ account: MailAccount) throws -> GmailCredentials {
        GmailCredentials(address: account.address, password: try accounts.password(for: account), proxy: preferences.proxy)
    }

    private func resetTranslation() {
        isTranslating = false
        translatedBody = nil
        translatedHTML = nil
        showingTranslation = false
    }

    private func toast(_ message: String) {
        toastMessage = message
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if toastMessage == message { toastMessage = nil }
        }
    }
}
