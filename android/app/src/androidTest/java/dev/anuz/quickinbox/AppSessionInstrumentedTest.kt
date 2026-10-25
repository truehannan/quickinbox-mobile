package dev.anuz.quickinbox

import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.google.gson.GsonBuilder
import dev.anuz.quickinbox.data.ApiDateAdapter
import dev.anuz.quickinbox.data.AccountRegistry
import dev.anuz.quickinbox.data.AppPreferences
import dev.anuz.quickinbox.data.AppSession
import dev.anuz.quickinbox.data.CredentialStore
import dev.anuz.quickinbox.data.MailboxCache
import dev.anuz.quickinbox.data.QuickInboxApi
import dev.anuz.quickinbox.data.SessionPhase
import dev.anuz.quickinbox.data.ThreadCache
import dev.anuz.quickinbox.domain.Credential
import dev.anuz.quickinbox.domain.ThreadDetail
import dev.anuz.quickinbox.domain.ThreadMessage
import dev.anuz.quickinbox.domain.ThreadSummary
import dev.anuz.quickinbox.domain.User
import kotlinx.coroutines.runBlocking
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import java.util.Date

@RunWith(AndroidJUnit4::class)
class AppSessionInstrumentedTest {
    private val context = ApplicationProvider.getApplicationContext<android.content.Context>()
    private val gson = GsonBuilder().registerTypeAdapter(Date::class.java, ApiDateAdapter()).create()
    private lateinit var server: MockWebServer
    private lateinit var credentials: CredentialStore
    private lateinit var preferences: AppPreferences
    private lateinit var accounts: AccountRegistry
    private lateinit var cache: MailboxCache
    private lateinit var threadCache: ThreadCache

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        credentials = CredentialStore(context, gson)
        preferences = AppPreferences(context, gson)
        accounts = AccountRegistry(context, gson)
        cache = MailboxCache(context, gson)
        threadCache = ThreadCache(context, gson)
        credentials.delete()
        preferences.clear()
        accounts.saveAccounts(emptyList())
        accounts.activeAccountId = null
        cache.clearAll()
        threadCache.clearAll()
    }

    @After
    fun tearDown() {
        credentials.delete()
        preferences.clear()
        accounts.saveAccounts(emptyList())
        accounts.activeAccountId = null
        cache.clearAll()
        threadCache.clearAll()
        server.shutdown()
    }

    @Test
    fun restoresSavedCredentialAndRefreshesCachedUser() = runBlocking {
        val user = User(id = "user-1", email = "user@example.com", name = "User")
        credentials.save(validCredential())
        server.enqueue(
            MockResponse().setResponseCode(200)
                .setBody("""{"user":{"id":"${user.id}","email":"${user.email}","name":"${user.name}"}}""")
        )
        val api = QuickInboxApi(gson)
        val session = AppSession(api, credentials, accounts, cache, threadCache, preferences)
        api.onUnauthorized = session::handleUnauthorized

        session.bootstrapIfNeeded()

        val phase = session.phase.value
        assertTrue(phase is SessionPhase.Authenticated)
        assertEquals(user, (phase as SessionPhase.Authenticated).user)
        assertEquals(user, credentials.load()?.cachedUser)
    }

    @Test
    fun expiredCredentialIsRemovedWithoutNetworkRequest() = runBlocking {
        credentials.save(validCredential().copy(expiresAt = Date(System.currentTimeMillis() - 1)))
        val api = QuickInboxApi(gson)
        val session = AppSession(api, credentials, accounts, cache, threadCache, preferences)
        api.onUnauthorized = session::handleUnauthorized

        session.bootstrapIfNeeded()

        assertTrue(session.phase.value is SessionPhase.Onboarding)
        assertNull(credentials.load())
        assertEquals(0, server.requestCount)
    }

    @Test
    fun unauthorizedClearsAllMailCaches() {
        val origin = validCredential().origin
        cache.save(
            listOf(ThreadSummary(threadId = "thread-1", latestId = "message-1")),
            total = 1,
            pageCount = 1,
            origin = origin,
            userId = "user-1"
        )
        threadCache.save(
            ThreadDetail(
                threadId = "thread-1",
                messages = listOf(ThreadMessage(id = "message-1", bodyText = "Sensitive"))
            ),
            origin,
            "user-1",
            "thread-1"
        )
        val api = QuickInboxApi(gson)
        val session = AppSession(api, credentials, accounts, cache, threadCache, preferences)

        session.handleUnauthorized()

        assertNull(cache.load(origin, "user-1"))
        assertNull(threadCache.load(origin, "user-1", "thread-1"))
        assertTrue(session.phase.value is SessionPhase.Onboarding)
    }

    @Test
    fun migratesLegacyCredentialToAccountRegistry() = runBlocking {
        val legacy = validCredential().copy(
            cachedUser = User(id = "legacy-user", email = "legacy@example.com", name = "Legacy")
        )
        credentials.save(legacy)
        val api = QuickInboxApi(gson)
        val session = AppSession(api, credentials, accounts, cache, threadCache, preferences)
        api.onUnauthorized = session::handleUnauthorized

        session.bootstrapIfNeeded()

        val activeId = session.activeAccountId.value
        assertTrue(activeId != null)
        assertEquals(1, session.accounts.value.size)
        assertEquals(legacy.cachedUser, credentials.load(activeId!!)?.cachedUser)
        assertNull(credentials.load())
    }

    @Test
    fun switchingAccountsInstallsSelectedCredentialAndClearsCaches() = runBlocking {
        val firstUser = User(id = "user-1", email = "a@example.com", name = "A")
        val secondUser = User(id = "user-2", email = "b@example.com", name = "B")
        val first = accounts.createAccount(firstUser, server.url("/a").toString().trimEnd('/'))
        val second = accounts.createAccount(secondUser, server.url("/b").toString().trimEnd('/'))
        accounts.saveAccounts(listOf(first, second))
        accounts.activeAccountId = first.id
        credentials.save(first.id, validCredential().copy(origin = first.origin, cachedUser = firstUser))
        credentials.save(second.id, validCredential().copy(origin = second.origin, cachedUser = secondUser))
        cache.save(
            listOf(ThreadSummary(threadId = "thread-1", latestId = "message-1")),
            total = 1,
            pageCount = 1,
            origin = first.origin,
            userId = firstUser.id
        )
        val api = QuickInboxApi(gson)
        val session = AppSession(api, credentials, accounts, cache, threadCache, preferences)
        api.onUnauthorized = session::handleUnauthorized

        session.bootstrapIfNeeded()
        session.switchAccount(second.id)

        assertEquals(second.id, session.activeAccountId.value)
        val phase = session.phase.value as SessionPhase.Authenticated
        assertEquals(secondUser, phase.user)
        assertEquals(second.origin, api.credential?.origin)
        assertNull(cache.load(first.origin, firstUser.id))
    }

    private fun validCredential() = Credential(
        origin = server.url("/").toString().trimEnd('/'),
        token = "session-token",
        expiresAt = Date(System.currentTimeMillis() + 60_000)
    )
}
