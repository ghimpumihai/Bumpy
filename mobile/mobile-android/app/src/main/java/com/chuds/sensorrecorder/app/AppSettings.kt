package com.chuds.sensorrecorder.app

import android.annotation.SuppressLint
import android.content.Context
import android.os.Build
import android.provider.Settings
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Base64
import com.chuds.sensorrecorder.BuildConfig
import com.chuds.sensorrecorder.core.AppLog
import com.chuds.sensorrecorder.core.LogLevel
import com.chuds.sensorrecorder.core.SessionMetadata
import com.chuds.sensorrecorder.core.SessionSetup
import com.chuds.sensorrecorder.core.text
import com.chuds.sensorrecorder.upload.UploadConfig
import java.security.KeyStore
import java.util.Locale
import java.util.UUID
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

object AppInfo {
    /** `1.0.0 (1) 3f2a9c1`: version, build, git commit stamped at build time. */
    val version = "${BuildConfig.VERSION_NAME} (${BuildConfig.VERSION_CODE}) ${BuildConfig.GIT_COMMIT}"
    const val SHORT_VERSION = BuildConfig.VERSION_NAME

    /** `Google Pixel 8`, for the Settings footer. */
    val modelName: String =
        if (Build.MODEL.startsWith(Build.MANUFACTURER, ignoreCase = true)) Build.MODEL
        else Build.MANUFACTURER.replaceFirstChar { it.uppercase() } + " " + Build.MODEL

    val deviceInfo = SessionMetadata.Device(Build.DEVICE, modelName, "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})")
}

/** Settings entered at runtime; the device key is encrypted with a key that never leaves the Keystore. */
class AppSettings(context: Context) {
    private val prefs = context.getSharedPreferences("settings", Context.MODE_PRIVATE)

    /** Debug builds only, set from an adb extra. */
    var dashboardOverride: String? = null

    private var cachedConfig: UploadConfig? = null // under this

    var baseUrlString: String
        get() = prefs.getString(KEY_BASE_URL, "").orEmpty()
        set(v) = synchronized(this) {
            prefs.edit().putString(KEY_BASE_URL, v.trim()).apply()
            cachedConfig = null
        }

    var deviceKey: String
        get() = prefs.getString(KEY_DEVICE_KEY, null)?.let { DeviceKeyCipher.decrypt(it) }.orEmpty()
        set(v) = synchronized(this) {
            val key = v.trim()
            if (key != deviceKey) {
                if (key.isEmpty()) prefs.edit().remove(KEY_DEVICE_KEY).apply()
                else DeviceKeyCipher.encrypt(key)?.let { prefs.edit().putString(KEY_DEVICE_KEY, it).apply() }
                cachedConfig = null
            }
        }

    /** Cached: the upload loop reads it for every request, and Keystore decryption takes milliseconds. */
    val uploadConfig: UploadConfig
        get() = synchronized(this) {
            cachedConfig ?: UploadConfig(UploadConfig.parseBaseUrl(baseUrlString), deviceKey).also { cachedConfig = it }
        }

    /** Web dashboard address for the menu and recap links; links are hidden while it is unset. */
    val dashboardUrl: String?
        get() = (dashboardOverride ?: BuildConfig.DASHBOARD_URL).trim().trimEnd('/').ifEmpty { null }

    /**
     * Stable per phone, and the same after a reinstall, so a device key stays valid. Derived from
     * ANDROID_ID (unique per phone and app signing key), never the ID itself. Upper case, like iOS's UUIDs.
     */
    val deviceId: String by lazy {
        prefs.getString(KEY_DEVICE_ID, null) ?: newDeviceId(context).also { prefs.edit().putString(KEY_DEVICE_ID, it).apply() }
    }

    @SuppressLint("HardwareIds")
    private fun newDeviceId(context: Context): String {
        val androidId = Settings.Secure.getString(context.contentResolver, Settings.Secure.ANDROID_ID)
        val id = if (androidId.isNullOrEmpty()) UUID.randomUUID()
        else UUID.nameUUIDFromBytes("com.chuds.sensorrecorder:$androidId".toByteArray())
        return id.toString().uppercase(Locale.ROOT)
    }

    /** Remembers the last mount and people values (see [SessionSetup.decode] for what is not remembered). */
    var setup: SessionSetup
        get() = prefs.getString(KEY_SETUP, null)?.let { runCatching { SessionSetup.decode(it) }.getOrNull() } ?: SessionSetup()
        set(v) = prefs.edit().putString(KEY_SETUP, v.encode()).apply()

    /** Settings → "Start trips automatically" (D59). Off by default. */
    var autoStartEnabled: Boolean
        get() = prefs.getBoolean(KEY_AUTO_START, false)
        set(v) = prefs.edit().putBoolean(KEY_AUTO_START, v).apply()

    /** car, bus or tram: every trip's `vehicle.type`, manual ones too (D59). */
    var vehicleType: String
        get() = prefs.getString(KEY_VEHICLE, null)?.takeIf { it in VEHICLE_TYPES } ?: "car"
        set(v) = prefs.edit().putString(KEY_VEHICLE, if (v in VEHICLE_TYPES) v else "car").apply()

    /** "Phone is firmly mounted": an automatic trip's `mount.rigid` (D59). Off by default. */
    var mounted: Boolean
        get() = prefs.getBoolean(KEY_MOUNTED, false)
        set(v) = prefs.edit().putBoolean(KEY_MOUNTED, v).apply()

    /** Background location was asked for once; Android shows no prompt after a refusal, only Settings. */
    var backgroundLocationAsked: Boolean
        get() = prefs.getBoolean(KEY_BACKGROUND_ASKED, false)
        set(v) = prefs.edit().putBoolean(KEY_BACKGROUND_ASKED, v).apply()

    companion object {
        val VEHICLE_TYPES = listOf("car", "bus", "tram")

        private const val KEY_AUTO_START = "autoStart.enabled"
        private const val KEY_VEHICLE = "trip.vehicleType"
        private const val KEY_MOUNTED = "autoStart.mounted"
        private const val KEY_BACKGROUND_ASKED = "autoStart.backgroundLocationAsked"
        private const val KEY_BASE_URL = "upload.baseURL"
        private const val KEY_DEVICE_KEY = "upload.deviceKey"
        private const val KEY_DEVICE_ID = "device.id"
        private const val KEY_SETUP = "setup.last"
    }
}

/** AES-GCM with a Keystore key. Not bound to unlocking, so uploads continue with the screen off. */
private object DeviceKeyCipher {
    private const val ALIAS = "com.chuds.sensorrecorder.deviceKey"
    private const val TRANSFORMATION = "AES/GCM/NoPadding"
    private const val IV_BYTES = 12

    private fun key(): SecretKey {
        val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        val gen = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore")
        gen.init(
            KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .build(),
        )
        return gen.generateKey()
    }

    fun encrypt(plain: String): String? = runCatching {
        val c = Cipher.getInstance(TRANSFORMATION)
        c.init(Cipher.ENCRYPT_MODE, key())
        Base64.encodeToString(c.iv + c.doFinal(plain.toByteArray()), Base64.NO_WRAP)
    }.onFailure { AppLog.log(LogLevel.ERROR, "device key not saved: ${it.text}") }.getOrNull()

    fun decrypt(stored: String): String? = runCatching {
        val bytes = Base64.decode(stored, Base64.NO_WRAP)
        val c = Cipher.getInstance(TRANSFORMATION)
        c.init(Cipher.DECRYPT_MODE, key(), GCMParameterSpec(128, bytes, 0, IV_BYTES))
        String(c.doFinal(bytes, IV_BYTES, bytes.size - IV_BYTES))
    }.onFailure { AppLog.log(LogLevel.ERROR, "device key not readable: ${it.text}") }.getOrNull()
}
