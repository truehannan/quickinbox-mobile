import Foundation
import Testing
@testable import quickinbox

@MainActor
struct CacheTests {
    @Test
    func mailboxRoundTripPreservesPaginationAndAccountIsolation() {
        let cache = MailboxCache()
        cache.clearAll()
        let origin = URL(string: "https://cache-test-\(UUID().uuidString).example")!
        let thread = summary(id: "thread-1")

        cache.save(
            threads: [thread],
            total: 42,
            pageCount: 5,
            currentPage: 3,
            origin: origin,
            userID: "user-a"
        )

        let restored = cache.load(origin: origin, userID: "user-a")
        #expect(restored?.threads == [thread])
        #expect(restored?.total == 42)
        #expect(restored?.pageCount == 5)
        #expect(restored?.currentPage == 3)
        #expect(cache.load(origin: origin, userID: "user-b") == nil)
        cache.clearAll()
    }

    @Test
    func threadRoundTripIsAccountScoped() {
        let cache = ThreadDetailCache()
        cache.clearAll()
        let origin = URL(string: "https://thread-test-\(UUID().uuidString).example")!
        let detail = threadDetail(id: "thread-1")

        cache.save(detail, origin: origin, userID: "user-a")

        #expect(cache.load(origin: origin, userID: "user-a", threadID: detail.threadID)?.detail == detail)
        #expect(cache.load(origin: origin, userID: "user-b", threadID: detail.threadID) == nil)
        #expect(cache.load(origin: origin, userID: "user-a", threadID: "thread-2") == nil)
        cache.clearAll()
    }

    @Test
    func threadCacheExpiresEntriesAtLifetimeBoundary() {
        let storedAt = Date(timeIntervalSince1970: 10_000)
        var currentDate = storedAt
        let cache = ThreadDetailCache(lifetime: 60, now: { currentDate })
        cache.clearAll()
        let origin = URL(string: "https://expiry-test-\(UUID().uuidString).example")!
        let detail = threadDetail(id: "expiring-thread")
        cache.save(detail, origin: origin, userID: "user")

        currentDate = storedAt.addingTimeInterval(60)
        #expect(cache.load(origin: origin, userID: "user", threadID: detail.threadID) != nil)

        currentDate = storedAt.addingTimeInterval(61)
        #expect(cache.load(origin: origin, userID: "user", threadID: detail.threadID) == nil)
        cache.clearAll()
    }

    @Test
    func threadCacheEvictsLeastRecentlyUsedEntry() {
        var currentDate = Date(timeIntervalSince1970: 20_000)
        let cache = ThreadDetailCache(accountLimit: 2, now: { currentDate })
        cache.clearAll()
        let origin = URL(string: "https://lru-test-\(UUID().uuidString).example")!

        for index in 1...3 {
            cache.save(threadDetail(id: "thread-\(index)"), origin: origin, userID: "user")
            currentDate.addTimeInterval(1)
        }

        #expect(cache.load(origin: origin, userID: "user", threadID: "thread-1") == nil)
        #expect(cache.load(origin: origin, userID: "user", threadID: "thread-2") != nil)
        #expect(cache.load(origin: origin, userID: "user", threadID: "thread-3") != nil)
        cache.clearAll()
    }

    @Test
    func appSessionMigratesLegacyCredentialIntoAccountRegistry() async {
        let suite = "cache-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = CredentialStore(service: suite)
        let registry = AccountRegistry(defaults: defaults)
        let cache = MailboxCache()
        let threadCache = ThreadDetailCache()
        cache.clearAll()
        threadCache.clearAll()
        registry.saveAccounts([])
        registry.activeAccountID = nil
        let legacyUser = User(id: "legacy-user", email: "legacy@example.com", name: "Legacy", isAdmin: false, createdAt: nil)
        let credential = Credential(
            origin: URL(string: "https://legacy-\(UUID().uuidString).example")!,
            token: "token",
            expiresAt: Date().addingTimeInterval(300),
            cachedUser: legacyUser
        )
        try? store.delete()
        try? store.save(credential)

        let session = AppSession(
            api: QuickInboxAPI(),
            credentialStore: store,
            accountRegistry: registry,
            mailboxCache: cache,
            threadCache: threadCache
        )
        await session.bootstrapIfNeeded()

        #expect(session.accounts.count == 1)
        #expect(session.activeAccountID != nil)
        #expect((try? store.load()) == nil)
        if let active = session.activeAccountID {
            #expect((try? store.load(accountID: active))?.cachedUser == legacyUser)
        }
        try? store.delete()
        defaults.removePersistentDomain(forName: suite)
    }

    @Test
    func appSessionSwitchesAndRemovesAccounts() async {
        let suite = "cache-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let store = CredentialStore(service: suite)
        let registry = AccountRegistry(defaults: defaults)
        let cache = MailboxCache()
        let threadCache = ThreadDetailCache()
        let session = AppSession(
            api: QuickInboxAPI(),
            credentialStore: store,
            accountRegistry: registry,
            mailboxCache: cache,
            threadCache: threadCache
        )

        let userA = User(id: "user-a", email: "a@example.com", name: "A", isAdmin: false, createdAt: nil)
        let userB = User(id: "user-b", email: "b@example.com", name: "B", isAdmin: false, createdAt: nil)
        session.didAuthenticate(
            credential: Credential(
                origin: URL(string: "https://a-\(UUID().uuidString).example")!,
                token: "token-a",
                expiresAt: Date().addingTimeInterval(300),
                cachedUser: userA
            ),
            user: userA
        )
        session.didAuthenticate(
            credential: Credential(
                origin: URL(string: "https://b-\(UUID().uuidString).example")!,
                token: "token-b",
                expiresAt: Date().addingTimeInterval(300),
                cachedUser: userB
            ),
            user: userB
        )

        let firstID = session.accounts.first(where: { $0.user.id == userA.id })!.id
        await session.switchAccount(firstID)
        if case .authenticated(let user) = session.phase {
            #expect(user.id == userA.id)
        } else {
            Issue.record("Expected authenticated phase after switching")
        }

        await session.removeAccount(firstID)
        #expect(session.accounts.count == 1)
        #expect(session.accounts.first?.user.id == userB.id)
        try? store.delete()
        if let remaining = session.accounts.first?.id {
            try? store.delete(accountID: remaining)
        }
        defaults.removePersistentDomain(forName: suite)
    }

    private func summary(id: String) -> ThreadSummary {
        ThreadSummary(
            threadID: id,
            latestID: "\(id)-message",
            subject: "Subject",
            preview: "Preview",
            participants: [],
            messageCount: 1,
            isRead: false,
            isStarred: false,
            isDraft: false,
            isArchived: false,
            hasAttachments: false,
            domainID: nil,
            status: nil,
            createdAt: Date(timeIntervalSince1970: 1_000)
        )
    }

    private func threadDetail(id: String) -> ThreadDetail {
        ThreadDetail(threadID: id, subject: "Subject", messages: [])
    }
}
