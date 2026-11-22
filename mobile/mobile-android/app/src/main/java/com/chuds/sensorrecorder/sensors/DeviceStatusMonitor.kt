package com.chuds.sensorrecorder.sensors

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.os.BatteryManager
import android.os.PowerManager
import android.os.StatFs
import com.chuds.sensorrecorder.core.Locked
import com.chuds.sensorrecorder.core.ThermalLevel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/**
 * Battery, thermal state, Battery Saver, free disk and network reachability (D1–D5), in the iOS app's
 * vocabulary. Everything is cached from callbacks (free disk: every 2 s on a background thread), so
 * [currentStatus] is cheap: it is read from the main thread at 8 Hz.
 */
class DeviceStatusMonitor(context: Context, private val dataDir: File) : DeviceStatusSource {
    private val power = context.getSystemService(PowerManager::class.java)
    private val state = Locked(DeviceStatus.UNKNOWN)

    init {
        state.update {
            it.copy(thermal = thermal(power.currentThermalStatus), lowPowerMode = power.isPowerSaveMode, freeDiskBytes = freeDisk())
        }
        power.addThermalStatusListener { s -> state.update { it.copy(thermal = thermal(s)) } }

        val battery = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) = onBattery(i)
        }
        context.registerReceiver(battery, IntentFilter(Intent.ACTION_BATTERY_CHANGED))?.let { onBattery(it) }
        val saver = object : BroadcastReceiver() {
            override fun onReceive(c: Context, i: Intent) {
                state.update { it.copy(lowPowerMode = power.isPowerSaveMode) }
            }
        }
        context.registerReceiver(saver, IntentFilter(PowerManager.ACTION_POWER_SAVE_MODE_CHANGED))

        network("unsatisfied", "none")
        context.getSystemService(ConnectivityManager::class.java).registerDefaultNetworkCallback(
            object : ConnectivityManager.NetworkCallback() {
                override fun onLost(n: Network) = network("unsatisfied", "none")
                override fun onCapabilitiesChanged(n: Network, c: NetworkCapabilities) = network("satisfied", type(c))
            },
        )

        Executors.newSingleThreadScheduledExecutor { r -> Thread(r, "sensorrecorder.disk").apply { isDaemon = true } }
            .scheduleWithFixedDelay({ state.update { it.copy(freeDiskBytes = freeDisk()) } }, 2, 2, TimeUnit.SECONDS)
    }

    override fun currentStatus(): DeviceStatus = state.current

    private fun network(status: String, type: String) {
        state.update { it.copy(networkStatus = status, networkType = type) }
    }

    private fun onBattery(i: Intent) {
        val level = i.getIntExtra(BatteryManager.EXTRA_LEVEL, -1)
        val scale = i.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
        val name = when {
            i.getIntExtra(BatteryManager.EXTRA_STATUS, -1) == BatteryManager.BATTERY_STATUS_FULL -> "full"
            // Also while the phone holds the charge below 100 %: it runs on the cable, as iOS reports it.
            i.getIntExtra(BatteryManager.EXTRA_PLUGGED, 0) != 0 -> "charging"
            i.hasExtra(BatteryManager.EXTRA_STATUS) -> "unplugged"
            else -> "unknown"
        }
        state.update {
            it.copy(batteryLevel = if (level < 0 || scale <= 0) -1f else level.toFloat() / scale, batteryState = name)
        }
    }

    private fun freeDisk(): Long = runCatching { StatFs(dataDir.path).availableBytes }.getOrDefault(-1L)

    private fun type(c: NetworkCapabilities) = when {
        c.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) -> "wifi"
        c.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) -> "cellular"
        c.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET) -> "wired"
        else -> "other"
    }

    private fun thermal(status: Int) = when (status) {
        PowerManager.THERMAL_STATUS_NONE -> ThermalLevel.NOMINAL
        PowerManager.THERMAL_STATUS_LIGHT, PowerManager.THERMAL_STATUS_MODERATE -> ThermalLevel.FAIR
        PowerManager.THERMAL_STATUS_SEVERE -> ThermalLevel.SERIOUS
        else -> ThermalLevel.CRITICAL
    }
}
