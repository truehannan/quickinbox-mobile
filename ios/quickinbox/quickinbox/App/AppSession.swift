import Foundation
import Observation

struct SessionAccount: Codable, Equatable, Identifiable, Sendable {
    let id: String
    let user: User
    let origin: URL

    var displayName: String {
        let trimmed = user.name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? user.email : trimmed
    }
}

@MainActor
final class AccountRegistry {
    private let defaults: UserDefaults
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var activeAccountID: String? {
        get { defaults.string(forKey: AppPreferences.activeAccountID) }
        set { defaults.set(newValue, forKey: AppPreferences.activeAccountID) }
    }

    func loadAccounts() -> [SessionAccount] {
        guard let data = defaults.data(forKey: AppPreferences.accounts) else { return [] }
        return (try? decoder.decode([SessionAccount].self, from: data)) ?? []
    }

    func saveAccounts(_ accounts: [SessionAccount]) {
        let unique = Array(Dictionary(grouping: accounts, by: \.id).compactMap { $0.value.first })
        if let data = try? encoder.encode(unique) {
            defaults.set(data, forKey: AppPreferences.accounts)
        } else {
            defaults.removeObject(forKey: AppPreferences.accounts)
        }
        if let active = activeAccountID, !unique.contains(where: { $0.id == active }) {
            activeAccountID = unique.first?.id
        }
    }

    func upsert(_ account: SessionAccount) {
        var accounts = loadAccounts()
        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            accounts[index] = account
        } else {
            accounts.append(account)
        }
        saveAccounts(accounts)
    }

    func remove(id: String) {
        let updated = loadAccounts().filter { $0.id != id }
        saveAccounts(updated)
        if activeAccountID == id { activeAccountID = updated.first?.id }
    }

    func find(origin: URL, userID: String) -> SessionAccount? {
        loadAccounts().first { $0.origin == origin && $0.user.id == userID }
    }
}

@MainActor
@Observable
final class AppSession {
    enum Phase {
        case booting
        case onboarding(message: String?)
        case authenticated(User)
        case restoreFailed(message: String)
    }

    let api: QuickInboxAPI
    let credentialStore: CredentialStore
    let accountRegistry: AccountRegistry
    let mailboxCache: MailboxCache
    let threadCache: ThreadDetailCache
    private(set) var phase: Phase = .booting
    private(set) var accounts: [SessionAccount] = []
    private(set) var activeAccountID: String?
    /// Set when the server revokes this device mid-session. Stay in the mailbox UI
    /// and show Sign Out on the session banner instead of error dialogs.
    private(set) var needsSignOut = false

    private var hasBootstrapped = false
    private var restoreGeneration = 0

    init(
        api: QuickInboxAPI = QuickInboxAPI(),
        credentialStore: CredentialStore = CredentialStore(),
        accountRegistry: AccountRegistry = AccountRegistry(),
        mailboxCache: MailboxCache,
        threadCache: ThreadDetailCache
    ) {
        self.api = api
        self.credentialStore = credentialStore
        self.accountRegistry = accountRegistry
        self.mailboxCache = mailboxCache
        self.threadCache = threadCache
        self.accounts = accountRegistry.loadAccounts()
        self.activeAccountID = accountRegistry.activeAccountID
        Task { await self.installUnauthorizedHandler() }
    }

    private func installUnauthorizedHandler() async {
        await api.setOnUnauthorized { [weak self] in
            Task { @MainActor in
                self?.handleUnauthorized()
            }
        }
    }

    func bootstrapIfNeeded() async {
        guard !hasBootstrapped else { return }
        hasBootstrapped = true
        // Yield so LaunchView can paint before Keychain work. Doing SecItem on the
        // main thread during ContentView.init leaves a blank system window (often
        // black), especially when relaunching under the Xcode debugger.
        await Task.yield()
        await restoreSession()
    }

    func retryRestore() async {
        await restoreSession()
    }

    func didAuthenticate(credential: Credential, user: User) {
        restoreGeneration += 1
        needsSignOut = false
        let previousActive = activeAccountID
        let account = (accountRegistry.find(origin: credential.origin, userID: user.id)
                       ?? SessionAccount(id: UUID().uuidString, user: user, origin: credential.origin))
        let updated = SessionAccount(id: account.id, user: user, origin: credential.origin)
        accountRegistry.upsert(updated)
        accountRegistry.activeAccountID = updated.id
        accounts = accountRegistry.loadAccounts()
        activeAccountID = updated.id
        let persisted = credential.caching(user: user)
        try? credentialStore.save(persisted, accountID: updated.id)
        cache(user)
        phase = .authenticated(user)
        if let previousActive, previousActive != updated.id {
            clearMailCaches()
            clearAccountScopedPreferences()
        }

        // Onboarding installs and saves the credential before invoking this callback.
        // Reinstalling here makes the session boundary explicit for alternate callers.
        Task { await api.install(persisted) }
    }

    func didDisconnect(message: String?) {
        restoreGeneration += 1
        needsSignOut = false
        clearMailCaches()
        clearAccountScopedPreferences()
        if let active = activeAccountID {
            try? credentialStore.delete(accountID: active)
            accountRegistry.remove(id: active)
            accounts = accountRegistry.loadAccounts()
            activeAccountID = accountRegistry.activeAccountID
        }
        if let next = activeAccountID,
           let credential = try? credentialStore.load(accountID: next),
           let user = credential.cachedUser,
           !credential.isExpired {
            cache(user)
            phase = .authenticated(user)
            Task { await api.install(credential) }
            return
        }
        clearCachedUser()
        phase = .onboarding(message: message)
        Task { await api.clearCredential() }
    }

    func removeLocalData() async {
        restoreGeneration += 1
        needsSignOut = false
        clearAccountScopedPreferences()
        clearCachedUser()
        for account in accountRegistry.loadAccounts() {
            try? credentialStore.delete(accountID: account.id)
        }
        if credentialStore.hasLegacyCredential() {
            try? credentialStore.delete()
        }
        accountRegistry.saveAccounts([])
        accountRegistry.activeAccountID = nil
        accounts = []
        activeAccountID = nil
        await api.clearCredential()
        clearMailCaches()
        phase = .onboarding(message: nil)
    }

    /// Clears local session after a mid-session revoke. Does not bounce to onboarding
    /// until the user taps Sign Out.
    func handleUnauthorized() {
        guard case .authenticated = phase, !needsSignOut else { return }
        needsSignOut = true
        if let active = activeAccountID {
            try? credentialStore.delete(accountID: active)
            accountRegistry.remove(id: active)
            accounts = accountRegistry.loadAccounts()
            activeAccountID = accountRegistry.activeAccountID
        } else {
            try? credentialStore.delete()
        }
        clearMailCaches()
        clearAccountScopedPreferences()
        Task { await api.clearCredential() }
    }

    func signOut() {
        didDisconnect(message: nil)
    }

    private func restoreSession() async {
        restoreGeneration += 1
        let generation = restoreGeneration
        phase = .booting

        do {
            await migrateLegacyAccountIfNeeded()
            var activeID = accountRegistry.activeAccountID
            var active = accountRegistry.loadAccounts().first { $0.id == activeID }
            if active == nil {
                active = accountRegistry.loadAccounts().first
                activeID = active?.id
                accountRegistry.activeAccountID = activeID
            }
            accounts = accountRegistry.loadAccounts()
            activeAccountID = activeID
            guard let activeID, active != nil else {
                guard generation == restoreGeneration else { return }
                await api.clearCredential()
                clearMailCaches()
                clearAccountScopedPreferences()
                phase = .onboarding(message: nil)
                return
            }
            guard let credential = try credentialStore.load(accountID: activeID) else {
                accountRegistry.remove(id: activeID)
                accounts = accountRegistry.loadAccounts()
                activeAccountID = accountRegistry.activeAccountID
                if activeAccountID != nil {
                    await restoreSession()
                    return
                }
                guard generation == restoreGeneration else { return }
                await api.clearCredential()
                clearMailCaches()
                clearAccountScopedPreferences()
                phase = .onboarding(message: nil)
                return
            }

            guard !credential.isExpired else {
                clearCachedUser()
                clearAccountScopedPreferences()
                try? credentialStore.delete(accountID: activeID)
                accountRegistry.remove(id: activeID)
                accounts = accountRegistry.loadAccounts()
                activeAccountID = accountRegistry.activeAccountID
                await api.clearCredential()
                clearMailCaches()
                if activeAccountID != nil {
                    await restoreSession()
                } else {
                    guard generation == restoreGeneration else { return }
                    phase = .onboarding(message: "Your saved session expired. Connect this device again.")
                }
                return
            }

            await api.install(credential)

            // A paired account always stores a cached user. Restore that account
            // immediately so launch is never blocked by a network round trip;
            // session validation can finish while the mailbox loads normally.
            if let cachedUser = credential.cachedUser ?? locallyCachedUser() {
                guard generation == restoreGeneration else { return }
                phase = .authenticated(cachedUser)
                await Task.yield()
            }

            let user = try await api.currentUser()
            cache(user)
            let persisted = credential.caching(user: user)
            try? credentialStore.save(persisted, accountID: activeID)
            if let account = active {
                accountRegistry.upsert(SessionAccount(id: account.id, user: user, origin: persisted.origin))
            }
            accounts = accountRegistry.loadAccounts()
            guard generation == restoreGeneration else { return }
            phase = .authenticated(user)
        } catch APIError.unauthorized {
            clearCachedUser()
            clearAccountScopedPreferences()
            if let active = activeAccountID {
                try? credentialStore.delete(accountID: active)
                accountRegistry.remove(id: active)
                accounts = accountRegistry.loadAccounts()
                activeAccountID = accountRegistry.activeAccountID
            } else {
                try? credentialStore.delete()
            }
            await api.clearCredential()
            clearMailCaches()
            if activeAccountID != nil {
                await restoreSession()
            } else {
                guard generation == restoreGeneration else { return }
                phase = .onboarding(message: "Your saved session is no longer valid. Connect this device again.")
            }
        } catch CredentialStoreError.corruptCredential {
            clearCachedUser()
            clearAccountScopedPreferences()
            await api.clearCredential()
            clearMailCaches()
            guard generation == restoreGeneration else { return }
            phase = .onboarding(message: "The saved session was invalid and has been removed.")
        } catch APIError.transport(_) {
            guard generation == restoreGeneration else { return }
            let savedCredential: Credential?
            if let active = activeAccountID {
                savedCredential = try? credentialStore.load(accountID: active)
            } else {
                savedCredential = try? credentialStore.load()
            }
            if let cachedUser = savedCredential?.cachedUser ?? locallyCachedUser() {
                // The cached account may already be visible. Keep it available
                // offline rather than returning to the launch screen.
                if case .booting = phase {
                    phase = .authenticated(cachedUser)
                }
            } else if case .booting = phase {
                phase = .restoreFailed(
                    message: "QuickInbox couldn’t reach your server and this account has not been cached yet."
                )
            }
        } catch {
            guard generation == restoreGeneration else { return }
            if case .booting = phase {
                phase = .restoreFailed(message: userFacingMessage(for: error))
            }
        }
    }

    private func userFacingMessage(for error: Error) -> String {
        if let localized = error as? LocalizedError,
           let description = localized.errorDescription,
           !description.isEmpty {
            return description
        }
        return "QuickInbox couldn’t reach your server. Check your connection and try again."
    }

    private func cache(_ user: User) {
        guard let data = try? JSONEncoder().encode(user) else { return }
        UserDefaults.standard.set(data, forKey: AppPreferences.cachedUser)
    }

    private func locallyCachedUser() -> User? {
        guard let data = UserDefaults.standard.data(forKey: AppPreferences.cachedUser) else {
            return nil
        }
        return try? JSONDecoder().decode(User.self, from: data)
    }

    private func clearCachedUser() {
        UserDefaults.standard.removeObject(forKey: AppPreferences.cachedUser)
    }

    private func clearAccountScopedPreferences() {
        UserDefaults.standard.removeObject(forKey: AppPreferences.selectedSendingAddressID)
    }

    private func clearMailCaches() {
        mailboxCache.clearAll()
        threadCache.clearAll()
    }

    func switchAccount(_ accountID: String) async {
        guard accountRegistry.loadAccounts().contains(where: { $0.id == accountID }) else { return }
        guard activeAccountID != accountID else { return }
        accountRegistry.activeAccountID = accountID
        activeAccountID = accountID
        clearMailCaches()
        clearAccountScopedPreferences()
        await restoreSession()
    }

    func removeAccount(_ accountID: String) async {
        guard accountRegistry.loadAccounts().contains(where: { $0.id == accountID }) else { return }
        let removingActive = activeAccountID == accountID
        try? credentialStore.delete(accountID: accountID)
        accountRegistry.remove(id: accountID)
        accounts = accountRegistry.loadAccounts()
        activeAccountID = accountRegistry.activeAccountID
        if removingActive {
            clearMailCaches()
            clearAccountScopedPreferences()
            if activeAccountID == nil {
                clearCachedUser()
                await api.clearCredential()
                phase = .onboarding(message: nil)
            } else {
                await restoreSession()
            }
        }
    }

    private func migrateLegacyAccountIfNeeded() async {
        let existing = accountRegistry.loadAccounts()
        if !existing.isEmpty {
            accounts = existing
            if accountRegistry.activeAccountID == nil {
                accountRegistry.activeAccountID = existing.first?.id
            }
            activeAccountID = accountRegistry.activeAccountID
            return
        }
        guard credentialStore.hasLegacyCredential(),
              let legacy = try? credentialStore.load() else { return }
        guard let user = legacy.cachedUser ?? locallyCachedUser() else { return }
        let account = SessionAccount(id: UUID().uuidString, user: user, origin: legacy.origin)
        accountRegistry.saveAccounts([account])
        accountRegistry.activeAccountID = account.id
        _ = try? credentialStore.migrateLegacyCredential(accountID: account.id)
        accounts = accountRegistry.loadAccounts()
        activeAccountID = account.id
    }
}
