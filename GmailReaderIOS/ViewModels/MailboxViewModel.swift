import Foundation
import MailCore

@MainActor
final class MailboxViewModel: ObservableObject {
    @Published var mailbox: MailboxKind = .inbox
    @Published var messages: [MailSummary] = []
    @Published var selectedSummary: MailSummary?
    @Published var selectedMessage: MailMessage?
    @Published var searchText = ""
    @Published private(set) var activeSearch = ""
    @Published var page = 1
    @Published var total = 0
    @Published var isLoading = false
    @Published var isLoadingMessage = false
    @Published var errorMessage: String?
    @Published var toastMessage: String?
    @Published var showingCompose = false
    @Published var showingAccounts = false

    let pageSize = 50
    private let service: MailCoreService
    private unowned let accounts: AccountStore
    private var listTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var generation = UUID()
    private var detailRequestID = UUID()

    init(accounts: AccountStore, service: MailCoreService) {
        self.accounts = accounts
        self.service = service
    }

    var pageCount: Int { max(1, Int(ceil(Double(total) / Double(pageSize)))) }
    var rangeText: String {
        guard total > 0 else { return "0 封" }
        let start = (page - 1) * pageSize + 1
        return "\(start)–\(min(page * pageSize, total)) / \(total)"
    }

    func accountChanged(from previousAccountID: UUID? = nil) {
        service.cancelOperations(for: previousAccountID)
        generation = UUID()
        detailRequestID = UUID()
        listTask?.cancel()
        detailTask?.cancel()
        selectedSummary = nil
        selectedMessage = nil
        searchText = ""
        activeSearch = ""
        page = 1
        reload()
    }

    func selectMailbox(_ value: MailboxKind) {
        mailbox = value
        searchText = ""
        activeSearch = ""
        page = 1
        selectedSummary = nil
        selectedMessage = nil
        reload()
    }

    func submitSearch() {
        activeSearch = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        page = 1
        selectedSummary = nil
        selectedMessage = nil
        reload()
    }

    func clearSearch() {
        searchText = ""
        activeSearch = ""
        page = 1
        reload()
    }

    func previousPage() {
        guard page > 1 else { return }
        page -= 1
        reload()
    }

    func nextPage() {
        guard page < pageCount else { return }
        page += 1
        reload()
    }

    func reload() {
        listTask?.cancel()
        guard let account = accounts.selectedAccount else {
            messages = []
            total = 0
            isLoading = false
            return
        }
        let requestGeneration = generation
        let requestedMailbox = mailbox
        let requestedPage = page
        let requestedQuery = activeSearch
        isLoading = true
        errorMessage = nil
        listTask = Task {
            do {
                let credentials = try accounts.credentials(for: account)
                let result = try await service.page(kind: requestedMailbox, page: requestedPage, pageSize: pageSize,
                                                    query: requestedQuery.isEmpty ? nil : requestedQuery,
                                                    credentials: credentials)
                try Task.checkCancellation()
                guard requestGeneration == generation, accounts.selectedAccountID == account.id,
                      requestedMailbox == mailbox, requestedPage == page, requestedQuery == activeSearch else { return }
                messages = result.messages
                total = result.total
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
        guard let account = accounts.selectedAccount else { return }
        let requestGeneration = generation
        let requestID = UUID()
        detailRequestID = requestID
        selectedSummary = summary
        selectedMessage = nil
        isLoadingMessage = true
        if !summary.isRead, let index = messages.firstIndex(where: { $0.id == summary.id }) {
            messages[index].isRead = true
        }
        detailTask = Task {
            do {
                let credentials = try accounts.credentials(for: account)
                if !summary.isRead {
                    try await service.setFlag(summary: summary, flag: .seen, enabled: true, credentials: credentials)
                }
                let message = try await service.message(summary: summary, credentials: credentials)
                try Task.checkCancellation()
                guard requestGeneration == generation, requestID == detailRequestID,
                      accounts.selectedAccountID == account.id else { return }
                selectedMessage = message
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled, requestGeneration == generation, requestID == detailRequestID else { return }
                errorMessage = error.localizedDescription
            }
            if requestGeneration == generation, requestID == detailRequestID { isLoadingMessage = false }
        }
    }

    func closeMessage() {
        detailTask?.cancel()
        detailRequestID = UUID()
        selectedSummary = nil
        selectedMessage = nil
        isLoadingMessage = false
    }

    func toggleStar(_ summary: MailSummary) {
        guard let account = accounts.selectedAccount else { return }
        let oldValue = messages.first(where: { $0.id == summary.id })?.isStarred ?? summary.isStarred
        if let index = messages.firstIndex(where: { $0.id == summary.id }) { messages[index].isStarred.toggle() }
        if selectedSummary?.id == summary.id { selectedSummary?.isStarred.toggle() }
        if selectedMessage?.id == summary.id { selectedMessage?.isStarred.toggle() }
        Task {
            do {
                try await service.setFlag(summary: summary, flag: .flagged, enabled: !oldValue,
                                          credentials: try accounts.credentials(for: account))
            } catch {
                if let index = messages.firstIndex(where: { $0.id == summary.id }) { messages[index].isStarred = oldValue }
                if selectedSummary?.id == summary.id { selectedSummary?.isStarred = oldValue }
                if selectedMessage?.id == summary.id { selectedMessage?.isStarred = oldValue }
                errorMessage = error.localizedDescription
            }
        }
    }

    func markUnread(_ summary: MailSummary) {
        guard let account = accounts.selectedAccount else { return }
        closeMessage()
        if let index = messages.firstIndex(where: { $0.id == summary.id }) { messages[index].isRead = false }
        Task {
            do {
                try await service.setFlag(summary: summary, flag: .seen, enabled: false,
                                          credentials: try accounts.credentials(for: account))
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func markAllRead() {
        guard let account = accounts.selectedAccount else { return }
        Task {
            do {
                let count = try await service.markAllRead(kind: mailbox, query: activeSearch,
                                                          credentials: try accounts.credentials(for: account))
                for index in messages.indices { messages[index].isRead = true }
                toast("已将 \(count) 封邮件标记为已读")
            } catch { errorMessage = error.localizedDescription }
        }
    }

    func verifyAndAdd(name: String, address: String, password: String) async -> Bool {
        let normalized = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let compactPassword = password.filter { !$0.isWhitespace }
        do {
            guard normalized.contains("@"), compactPassword.count >= 16 else {
                throw GmailReaderError.configuration("请输入有效的 Gmail 地址和 16 位应用专用密码")
            }
            let temporary = MailAccount(name: name, address: normalized)
            try await service.verify(credentials: MailCredentials(account: temporary, password: compactPassword))
            let previous = accounts.selectedAccountID
            _ = try accounts.addVerified(name: name, address: normalized, password: compactPassword)
            accountChanged(from: previous)
            toast("账号已保存到 iPhone 钥匙串")
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func delete(_ account: MailAccount) {
        let previous = accounts.selectedAccountID
        do {
            try accounts.delete(account)
            accountChanged(from: previous)
        } catch { errorMessage = error.localizedDescription }
    }

    func send(recipients: [String], subject: String, body: String) async -> Bool {
        guard let account = accounts.selectedAccount else { return false }
        do {
            try await service.send(recipients: recipients, subject: subject, body: body,
                                   credentials: try accounts.credentials(for: account))
            toast("邮件已发送")
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func toast(_ text: String) {
        toastMessage = text
        Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if toastMessage == text { toastMessage = nil }
        }
    }
}
