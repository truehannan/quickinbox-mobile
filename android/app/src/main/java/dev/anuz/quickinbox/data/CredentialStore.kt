package dev.anuz.quickinbox.data

import android.content.Context
import androidx.security.crypto.EncryptedSharedPreferences
import androidx.security.crypto.MasterKey
import com.google.gson.Gson
import com.google.gson.JsonSyntaxException
import dev.anuz.quickinbox.domain.Credential

class CredentialStore(context: Context, private val gson: Gson) {
    private val prefs = EncryptedSharedPreferences.create(
        context,
        PREFS_NAME,
        MasterKey.Builder(context).setKeyScheme(MasterKey.KeyScheme.AES256_GCM).build(),
        EncryptedSharedPreferences.PrefKeyEncryptionScheme.AES256_SIV,
        EncryptedSharedPreferences.PrefValueEncryptionScheme.AES256_GCM
    )

    fun load(): Credential? {
        return load(KEY)
    }

    fun load(accountId: String): Credential? {
        val json = prefs.getString(keyForAccount(accountId), null) ?: return null
        return try {
            gson.fromJson(json, Credential::class.java)
        } catch (_: JsonSyntaxException) {
            delete(accountId)
            throw ApiError.CorruptCredential()
        }
    }

    fun save(credential: Credential) {
        save(KEY, credential)
    }

    fun save(accountId: String, credential: Credential) {
        prefs.edit().putString(keyForAccount(accountId), gson.toJson(credential)).apply()
    }

    fun delete() {
        delete(KEY)
    }

    fun delete(accountId: String) {
        prefs.edit().remove(keyForAccount(accountId)).apply()
    }

    private fun keyForAccount(accountId: String) = if (accountId == KEY) KEY else "$KEY:$accountId"

    fun hasLegacyCredential(): Boolean = prefs.contains(KEY)

    fun migrateLegacyCredential(accountId: String): Credential? {
        val legacy = load() ?: return null
        save(accountId, legacy)
        delete()
        return legacy
    }

    companion object {
        const val PREFS_NAME = "quickinbox_credentials"
        const val KEY = "mobile-session"
    }
}
