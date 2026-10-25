package dev.anuz.quickinbox.data

import android.content.Context
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import dev.anuz.quickinbox.domain.User
import java.util.UUID

data class SessionAccount(
    val id: String,
    val user: User,
    val origin: String
) {
    val displayName: String get() = user.name.ifBlank { user.email }
}

class AccountRegistry(context: Context, private val gson: Gson) {
    private val prefs = context.getSharedPreferences("quickinbox_accounts", Context.MODE_PRIVATE)

    var activeAccountId: String?
        get() = prefs.getString(ACTIVE_ACCOUNT_ID, null)
        set(value) {
            prefs.edit().apply {
                if (value == null) remove(ACTIVE_ACCOUNT_ID) else putString(ACTIVE_ACCOUNT_ID, value)
            }.apply()
        }

    fun loadAccounts(): List<SessionAccount> {
        val json = prefs.getString(ACCOUNTS, null) ?: return emptyList()
        return runCatching {
            gson.fromJson<List<SessionAccount>>(json, object : TypeToken<List<SessionAccount>>() {}.type)
                ?.filter { it.id.isNotBlank() && it.origin.isNotBlank() && it.user.id.isNotBlank() }
                .orEmpty()
        }.getOrDefault(emptyList())
    }

    fun saveAccounts(accounts: List<SessionAccount>) {
        val unique = accounts.distinctBy { it.id }
        prefs.edit().putString(ACCOUNTS, gson.toJson(unique)).apply()
        if (activeAccountId != null && unique.none { it.id == activeAccountId }) {
            activeAccountId = unique.firstOrNull()?.id
        }
    }

    fun upsert(account: SessionAccount) {
        val accounts = loadAccounts().toMutableList()
        val index = accounts.indexOfFirst { it.id == account.id }
        if (index >= 0) accounts[index] = account else accounts += account
        saveAccounts(accounts)
    }

    fun remove(accountId: String) {
        val updated = loadAccounts().filterNot { it.id == accountId }
        saveAccounts(updated)
        if (activeAccountId == accountId) activeAccountId = updated.firstOrNull()?.id
    }

    fun findByOriginAndUser(origin: String, userId: String): SessionAccount? =
        loadAccounts().firstOrNull { it.origin == origin && it.user.id == userId }

    fun createAccount(user: User, origin: String): SessionAccount =
        SessionAccount(id = UUID.randomUUID().toString(), user = user, origin = origin)

    companion object {
        private const val ACCOUNTS = "quickinbox.accounts"
        private const val ACTIVE_ACCOUNT_ID = "quickinbox.activeAccountId"
    }
}
