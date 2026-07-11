import Foundation

@MainActor
final class AccountStore: ObservableObject {
    @Published private(set) var accounts: [MailAccount] = []
    @Published var selectedAccountID: UUID?

    private let keychain: KeychainStore
    private let fileURL: URL
    private let defaults = UserDefaults.standard

    init(keychain: KeychainStore = .shared) {
        self.keychain = keychain
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Gmail Reader", isDirectory: true)
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        self.fileURL = support.appendingPathComponent("native-accounts.json")
        load()
        migrateLegacyConfiguration(in: support)
        if let value = defaults.string(forKey: "selectedAccountID"), let id = UUID(uuidString: value),
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

    func select(_ account: MailAccount) {
        selectedAccountID = account.id
        defaults.set(account.id.uuidString, forKey: "selectedAccountID")
    }

    func add(name: String, address: String, appPassword: String) throws -> MailAccount {
        let normalizedAddress = address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let password = appPassword.filter { !$0.isWhitespace }
        guard normalizedAddress.contains("@"), !normalizedAddress.contains(where: { $0.isWhitespace }) else {
            throw GmailReaderError.configuration("请输入有效的 Gmail 地址")
        }
        guard password.count >= 16 else {
            throw GmailReaderError.configuration("请输入 16 位 Google 应用专用密码")
        }
        guard !accounts.contains(where: { $0.address.caseInsensitiveCompare(normalizedAddress) == .orderedSame }) else {
            throw GmailReaderError.configuration("这个 Gmail 账号已经存在")
        }
        let account = MailAccount(name: name.isEmpty ? normalizedAddress.components(separatedBy: "@").first ?? normalizedAddress : name,
                                  address: normalizedAddress)
        try keychain.save(password: password, for: account.id)
        accounts.append(account)
        do { try persist() } catch {
            try? keychain.deletePassword(for: account.id)
            accounts.removeAll { $0.id == account.id }
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

    func password(for account: MailAccount) throws -> String {
        try keychain.password(for: account.id)
    }

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([MailAccount].self, from: data) else { return }
        accounts = decoded
    }

    private func persist() throws {
        let data = try JSONEncoder().encode(accounts)
        try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }

    private func migrateLegacyConfiguration(in support: URL) {
        var candidates: [(name: String, address: String, password: String)] = []
        let legacyAccounts = support.appendingPathComponent("accounts.json")
        if let data = try? Data(contentsOf: legacyAccounts),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let items = object["accounts"] as? [[String: Any]] {
            for item in items {
                if let address = item["address"] as? String, let password = item["app_password"] as? String {
                    candidates.append((item["name"] as? String ?? "", address, password))
                }
            }
        }
        let legacyEnv = support.appendingPathComponent(".env")
        if let text = try? String(contentsOf: legacyEnv, encoding: .utf8) {
            let values = parseEnv(text)
            if let address = values["GMAIL_ADDRESS"], let password = values["GMAIL_APP_PASSWORD"] {
                candidates.append((values["GMAIL_ACCOUNT_NAME"] ?? "", address, password))
            }
        }

        var changed = false
        var allCredentialsSecured = !candidates.isEmpty
        for candidate in candidates {
            let address = candidate.address.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let password = candidate.password.filter { !$0.isWhitespace }
            guard !address.isEmpty, !password.isEmpty else {
                allCredentialsSecured = false
                continue
            }
            if let existing = accounts.first(where: { $0.address == address }) {
                if (try? keychain.password(for: existing.id)) == nil {
                    do { try keychain.save(password: password, for: existing.id) }
                    catch { allCredentialsSecured = false }
                }
                continue
            }
            let account = MailAccount(name: candidate.name.isEmpty ? address.components(separatedBy: "@").first ?? address : candidate.name,
                                      address: address)
            do {
                try keychain.save(password: password, for: account.id)
                accounts.append(account)
                changed = true
            } catch { allCredentialsSecured = false }
        }
        if changed {
            do { try persist() }
            catch { allCredentialsSecured = false }
        }
        if allCredentialsSecured {
            try? FileManager.default.removeItem(at: legacyAccounts)
            try? FileManager.default.removeItem(at: legacyEnv)
        }
    }

    private func parseEnv(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#"), let equal = line.firstIndex(of: "=") else { continue }
            let key = line[..<equal].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equal)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, (value.hasPrefix("\"") && value.hasSuffix("\"") || value.hasPrefix("'") && value.hasSuffix("'")) {
                value.removeFirst(); value.removeLast()
            }
            result[String(key)] = value
        }
        return result
    }
}
