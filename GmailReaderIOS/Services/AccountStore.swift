import Foundation

@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var accounts: [MailAccount] = []
    @Published private(set) var selectedAccountID: UUID?

    private let keychain: KeychainStore
    private let fileURL: URL
    private let defaults = UserDefaults.standard

    init(keychain: KeychainStore = .shared) {
        self.keychain = keychain
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("GmailReaderIOS", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        fileURL = support.appendingPathComponent("accounts.json")
        load()
        if let raw = defaults.string(forKey: "selectedAccountID"), let id = UUID(uuidString: raw),
           accounts.contains(where: { $0.id == id }) {
            selectedAccountID = id
        } else {
            selectedAccountID = accounts.first?.id
        }
    }

    var selectedAccount: MailAccount? {
        guard let selectedAccountID else { return nil }
        return accounts.first { $0.id == selectedAccountID }
    }

    func credentials(for account: MailAccount) throws -> MailCredentials {
        MailCredentials(account: account, password: try keychain.password(for: account.id))
    }

    func select(_ account: MailAccount) {
        selectedAccountID = account.id
        defaults.set(account.id.uuidString, forKey: "selectedAccountID")
    }

    func addVerified(name: String, address: String, password: String) throws -> MailAccount {
        let normalized = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !accounts.contains(where: { $0.address.caseInsensitiveCompare(normalized) == .orderedSame }) else {
            throw GmailReaderError.configuration("这个 Gmail 账号已经存在")
        }
        let account = MailAccount(name: name.isEmpty ? normalized.components(separatedBy: "@").first ?? normalized : name,
                                  address: normalized)
        try keychain.save(password: password, for: account.id)
        accounts.append(account)
        do { try persist() }
        catch {
            accounts.removeAll { $0.id == account.id }
            try? keychain.deletePassword(for: account.id)
            throw error
        }
        select(account)
        return account
    }

    func delete(_ account: MailAccount) throws {
        try keychain.deletePassword(for: account.id)
        accounts.removeAll { $0.id == account.id }
        try persist()
        if selectedAccountID == account.id {
            selectedAccountID = accounts.first?.id
            defaults.set(selectedAccountID?.uuidString, forKey: "selectedAccountID")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let value = try? JSONDecoder().decode([MailAccount].self, from: data) else { return }
        accounts = value
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(accounts)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
    }
}
