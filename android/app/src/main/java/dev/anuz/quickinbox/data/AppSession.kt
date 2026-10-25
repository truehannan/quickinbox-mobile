package dev.anuz.quickinbox.data

import dev.anuz.quickinbox.domain.Credential
import dev.anuz.quickinbox.domain.User
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

sealed class SessionPhase {
    data object Booting : SessionPhase()
    data class Onboarding(val message: String? = null) : SessionPhase()
    data class Authenticated(val user: User) : SessionPhase()
    data class RestoreFailed(val message: String) : SessionPhase()
}

class AppSession(
    val api: QuickInboxApi,
    val credentialStore: CredentialStore,
    val accountRegistry: AccountRegistry,
    val mailboxCache: MailboxCache,
    val threadCache: ThreadCache,
    val preferences: AppPreferences
) {
    private val mutex = Mutex()
    private val _phase = MutableStateFlow<SessionPhase>(SessionPhase.Booting)
    val phase: StateFlow<SessionPhase> = _phase.asStateFlow()
    private val _accounts = MutableStateFlow(accountRegistry.loadAccounts())
    val accounts: StateFlow<List<SessionAccount>> = _accounts.asStateFlow()
    private val _activeAccountId = MutableStateFlow(accountRegistry.activeAccountId)
    val activeAccountId: StateFlow<String?> = _activeAccountId.asStateFlow()

    private var hasBootstrapped = false
    private var restoreGeneration = 0

    init {
        api.onUnauthorized = {
            // Network threads may observe 401 while a mailbox is open.
            // The UI collects phase and returns to onboarding.
        }
    }

    suspend fun bootstrapIfNeeded() {
        mutex.withLock {
            if (hasBootstrapped) return
            hasBootstrapped = true
        }
        restoreSession()
    }

    suspend fun retryRestore() = restoreSession()

    fun didAuthenticate(credential: Credential, user: User) {
        restoreGeneration += 1
        val previousActive = accountRegistry.activeAccountId
        val existing = accountRegistry.findByOriginAndUser(credential.origin, user.id)
        val account = (existing ?: accountRegistry.createAccount(user, credential.origin))
            .copy(user = user, origin = credential.origin)
        accountRegistry.upsert(account)
        accountRegistry.activeAccountId = account.id
        _accounts.value = accountRegistry.loadAccounts()
        _activeAccountId.value = account.id
        preferences.cachedUser = user
        val persisted = credential.caching(user)
        credentialStore.save(account.id, persisted)
        if (previousActive != null && previousActive != account.id) {
            mailboxCache.clearAll()
            threadCache.clearAll()
            preferences.selectedSendingAddressId = null
        }
        api.install(persisted)
        _phase.value = SessionPhase.Authenticated(user)
    }

    fun didDisconnect(message: String?) {
        restoreGeneration += 1
        val active = accountRegistry.activeAccountId
        if (active != null) {
            credentialStore.delete(active)
            accountRegistry.remove(active)
            _accounts.value = accountRegistry.loadAccounts()
            _activeAccountId.value = accountRegistry.activeAccountId
        }
        mailboxCache.clearAll()
        threadCache.clearAll()
        preferences.selectedSendingAddressId = null
        val nextId = _activeAccountId.value
        if (nextId != null) {
            val credential = runCatching { credentialStore.load(nextId) }.getOrNull()
            val cachedUser = credential?.cachedUser
            if (credential != null && cachedUser != null && !credential.isExpired) {
                preferences.cachedUser = cachedUser
                api.install(credential)
                _phase.value = SessionPhase.Authenticated(cachedUser)
                return
            }
        }
        preferences.cachedUser = null
        api.clearCredential()
        _phase.value = SessionPhase.Onboarding(message)
    }

    suspend fun removeLocalData() {
        restoreGeneration += 1
        withContext(Dispatchers.IO) {
            accountRegistry.loadAccounts().forEach { credentialStore.delete(it.id) }
            if (credentialStore.hasLegacyCredential()) credentialStore.delete()
        }
        accountRegistry.saveAccounts(emptyList())
        accountRegistry.activeAccountId = null
        _accounts.value = emptyList()
        _activeAccountId.value = null
        preferences.clear()
        api.clearCredential()
        mailboxCache.clearAll()
        threadCache.clearAll()
        _phase.value = SessionPhase.Onboarding(null)
    }

    fun handleUnauthorized() {
        restoreGeneration += 1
        preferences.cachedUser = null
        try {
            accountRegistry.activeAccountId?.let { credentialStore.delete(it) } ?: credentialStore.delete()
        } catch (_: Exception) {
        }
        accountRegistry.activeAccountId?.let { accountRegistry.remove(it) }
        _accounts.value = accountRegistry.loadAccounts()
        _activeAccountId.value = accountRegistry.activeAccountId
        api.clearCredential()
        mailboxCache.clearAll()
        threadCache.clearAll()
        preferences.selectedSendingAddressId = null
        _phase.value = SessionPhase.Onboarding("Your saved session is no longer valid. Connect this device again.")
    }

    suspend fun switchAccount(accountId: String) {
        if (_phase.value is SessionPhase.Booting) return
        if (accountId == accountRegistry.activeAccountId) return
        if (accountRegistry.loadAccounts().none { it.id == accountId }) return
        accountRegistry.activeAccountId = accountId
        _activeAccountId.value = accountId
        mailboxCache.clearAll()
        threadCache.clearAll()
        preferences.selectedSendingAddressId = null
        restoreSession()
    }

    suspend fun removeAccount(accountId: String) {
        if (accountRegistry.loadAccounts().none { it.id == accountId }) return
        val isActive = accountRegistry.activeAccountId == accountId
        withContext(Dispatchers.IO) { credentialStore.delete(accountId) }
        accountRegistry.remove(accountId)
        _accounts.value = accountRegistry.loadAccounts()
        _activeAccountId.value = accountRegistry.activeAccountId
        if (isActive) {
            preferences.selectedSendingAddressId = null
            mailboxCache.clearAll()
            threadCache.clearAll()
            if (_activeAccountId.value == null) {
                preferences.cachedUser = null
                api.clearCredential()
                _phase.value = SessionPhase.Onboarding(null)
            } else {
                restoreSession()
            }
        }
    }

    private suspend fun restoreSession() {
        restoreGeneration += 1
        val generation = restoreGeneration
        _phase.value = SessionPhase.Booting

        try {
            migrateLegacyAccountIfNeeded()
            var activeId = accountRegistry.activeAccountId
            var account = accountRegistry.loadAccounts().firstOrNull { it.id == activeId }
            if (account == null) {
                account = accountRegistry.loadAccounts().firstOrNull()
                activeId = account?.id
                accountRegistry.activeAccountId = activeId
                _activeAccountId.value = activeId
            }
            if (activeId == null || account == null) {
                api.clearCredential()
                preferences.cachedUser = null
                if (generation == restoreGeneration) _phase.value = SessionPhase.Onboarding(null)
                return
            }
            _accounts.value = accountRegistry.loadAccounts()
            val credential = withContext(Dispatchers.IO) { credentialStore.load(activeId) }
            if (credential == null) {
                accountRegistry.remove(activeId)
                _accounts.value = accountRegistry.loadAccounts()
                _activeAccountId.value = accountRegistry.activeAccountId
                api.clearCredential()
                if (_activeAccountId.value != null) {
                    restoreSession()
                } else if (generation == restoreGeneration) {
                    _phase.value = SessionPhase.Onboarding(null)
                }
                return
            }
            if (credential.isExpired) {
                preferences.cachedUser = null
                withContext(Dispatchers.IO) { credentialStore.delete(activeId) }
                accountRegistry.remove(activeId)
                _accounts.value = accountRegistry.loadAccounts()
                _activeAccountId.value = accountRegistry.activeAccountId
                api.clearCredential()
                if (_activeAccountId.value != null) {
                    restoreSession()
                } else if (generation == restoreGeneration) {
                    _phase.value = SessionPhase.Onboarding(
                        "Your saved session expired. Connect this device again."
                    )
                }
                return
            }

            api.install(credential)
            val cachedUser = credential.cachedUser ?: preferences.cachedUser
            if (cachedUser != null && generation == restoreGeneration) {
                _phase.value = SessionPhase.Authenticated(cachedUser)
            }

            val user = withContext(Dispatchers.IO) { api.currentUser() }
            preferences.cachedUser = user
            withContext(Dispatchers.IO) { credentialStore.save(activeId, credential.caching(user)) }
            accountRegistry.upsert(account.copy(user = user, origin = credential.origin))
            _accounts.value = accountRegistry.loadAccounts()
            if (generation == restoreGeneration) _phase.value = SessionPhase.Authenticated(user)
        } catch (_: ApiError.Unauthorized) {
            preferences.cachedUser = null
            val activeId = accountRegistry.activeAccountId
            withContext(Dispatchers.IO) {
                if (activeId != null) runCatching { credentialStore.delete(activeId) }
                else runCatching { credentialStore.delete() }
            }
            activeId?.let { accountRegistry.remove(it) }
            _accounts.value = accountRegistry.loadAccounts()
            _activeAccountId.value = accountRegistry.activeAccountId
            api.clearCredential()
            mailboxCache.clearAll()
            threadCache.clearAll()
            preferences.selectedSendingAddressId = null
            if (_activeAccountId.value != null) {
                restoreSession()
            } else if (generation == restoreGeneration) {
                _phase.value = SessionPhase.Onboarding(
                    "Your saved session is no longer valid. Connect this device again."
                )
            }
        } catch (_: ApiError.CorruptCredential) {
            preferences.cachedUser = null
            api.clearCredential()
            if (generation == restoreGeneration) {
                _phase.value = SessionPhase.Onboarding(
                    "The saved session was invalid and has been removed."
                )
            }
        } catch (error: ApiError.Transport) {
            if (generation != restoreGeneration) return
            val activeId = accountRegistry.activeAccountId
            val saved = withContext(Dispatchers.IO) {
                runCatching { if (activeId != null) credentialStore.load(activeId) else credentialStore.load() }.getOrNull()
            }
            val cachedUser = saved?.cachedUser ?: preferences.cachedUser
            if (cachedUser != null) {
                if (_phase.value is SessionPhase.Booting) {
                    _phase.value = SessionPhase.Authenticated(cachedUser)
                }
            } else if (_phase.value is SessionPhase.Booting) {
                _phase.value = SessionPhase.RestoreFailed(
                    "QuickInbox couldn’t reach your server and this account has not been cached yet."
                )
            }
        } catch (error: Exception) {
            if (generation != restoreGeneration) return
            if (_phase.value is SessionPhase.Booting) {
                _phase.value = SessionPhase.RestoreFailed(
                    error.message?.takeIf { it.isNotBlank() }
                        ?: "QuickInbox couldn’t reach your server. Check your connection and try again."
                )
            }
        }
    }

    private suspend fun migrateLegacyAccountIfNeeded() {
        val accounts = accountRegistry.loadAccounts()
        if (accounts.isNotEmpty()) {
            _accounts.value = accounts
            if (accountRegistry.activeAccountId == null) {
                accountRegistry.activeAccountId = accounts.first().id
            }
            _activeAccountId.value = accountRegistry.activeAccountId
            return
        }
        if (!credentialStore.hasLegacyCredential()) return
        val legacy = withContext(Dispatchers.IO) { credentialStore.load() } ?: return
        val user = legacy.cachedUser ?: preferences.cachedUser ?: return
        val account = accountRegistry.createAccount(user, legacy.origin)
        accountRegistry.saveAccounts(listOf(account))
        accountRegistry.activeAccountId = account.id
        withContext(Dispatchers.IO) { credentialStore.migrateLegacyCredential(account.id) }
        _accounts.value = accountRegistry.loadAccounts()
        _activeAccountId.value = account.id
    }
}
