package wheellog.core

import io.github.tritbool.euc.ble.models.EUCData
import io.github.tritbool.euc.ble.protocols.CommandType
import io.github.tritbool.euc.ble.protocols.CommandValue
import io.github.tritbool.euc.ble.protocols.ProtocolOutput
import io.github.tritbool.euc.ble.protocols.ProtocolPollingPlan
import io.github.tritbool.euc.ble.protocols.ProtocolQuerySpec
import io.github.tritbool.euc.ble.protocols.SyncEucProtocol
import kotlin.time.Clock

// Wire format and register IDs follow the GPL-3.0 WheelLog.Android Ninebot adapters.
internal class NinebotReader(
    private val isZ: Boolean,
    private val transport: SyncEucProtocol
) : SyncEucProtocol by transport {
    private val input = ArrayDeque<Byte>()
    private val readings = ArrayDeque<ProtocolOutput>()
    private val header = if (isZ) byteArrayOf(0x5a, 0xa5.toByte()) else byteArrayOf(0x55, 0xaa.toByte())
    private var streamKey = ByteArray(16)
    private var bleInitialized = !isZ
    private var classicAddress = 0

    override val supportedCommandTypes: Set<CommandType> = emptySet()

    override fun resetSession() {
        transport.resetSession()
        input.clear()
        readings.clear()
        bleInitialized = !isZ
        classicAddress = 0
        responseRegister = null
        attempt = 0
        streamKey = ByteArray(16)
    }

    override fun getPollingPlan(): ProtocolPollingPlan {
        val startup = if (isZ) listOf(
            query("ninebot-z.ble-version", 0x68, timeout = 450),
            query("ninebot-z.session-key", SESSION_KEY, timeout = 450),
            query("ninebot-z.firmware", 0x1a, timeout = 450),
            query("ninebot-z.identity", 0x10, timeout = 450)
        ) else emptyList()
        return ProtocolPollingPlan(true, startup, listOf(
            query("ninebot.realtime", 0xb0, interval = 250, timeout = 350)
        ))
    }

    override fun createCommand(commandType: CommandType, value: CommandValue): ByteArray {
        val register = (value as? CommandValue.Integer)?.value ?: return byteArrayOf()
        if (commandType != CommandType.CUSTOM) return byteArrayOf()
        if (register == SESSION_KEY) {
            return if (bleInitialized) byteArrayOf() else packet(byteArrayOf(0, 0x3e, 0x16, 0x5b, 0))
        }
        if (isZ && !bleInitialized && register == 0xb0) return zRequest(0x68, 2)
        val count = when (register) { 0x10 -> 14; 0xb0 -> 32; else -> 2 }
        return if (isZ) zRequest(register, count) else {
            val address = classicAddress.takeIf { it != 0 } ?: CLASSIC_ADDRESSES[attempt++ % CLASSIC_ADDRESSES.size]
            packet(byteArrayOf(3, address.toByte(), 1, register.toByte(), count.toByte()))
        }
    }

    private var attempt = 0

    // A valid frame can span several BLE notifications, so match by the last decoded packet.
    private var responseRegister: Int? = null
    override fun matchesQueryResponse(query: ProtocolQuerySpec, data: ByteArray): Boolean =
        responseRegister == (query.value as? CommandValue.Integer)?.value

    override fun onNotification(data: ByteArray) {
        responseRegister = null
        input.addAll(data.toList())
        val extra = if (isZ) 9 else 6
        while (input.size >= 3) {
            if (input[0] != header[0] || input[1] != header[1]) {
                input.removeFirst()
                continue
            }
            val length = unsigned(input[2]) + extra
            if (input.size < length) return
            val frame = ByteArray(length) { input[it] }
            if (isZ) crypt(frame)
            if (checksum(frame, 2, length - 2) != little16(frame, length - 2)) {
                input.removeFirst()
                continue
            }
            repeat(length) { input.removeFirst() }
            if (isZ) {
                val register = unsigned(frame[6])
                responseRegister = register
                if (register == 0x68) bleInitialized = true
                if (register == 0 && unsigned(frame[3]) == 0x16 && unsigned(frame[2]) == 16) {
                    streamKey = frame.copyOfRange(7, 23)
                    bleInitialized = true
                    responseRegister = SESSION_KEY
                }
                transport.onNotification(frame)
            } else {
                val address = unsigned(frame[4])
                val register = unsigned(frame[5])
                if (unsigned(frame[3]) == 1 && address in CLASSIC_ADDRESSES) {
                    classicAddress = address
                    responseRegister = register
                    if (register == 0xb0 && length >= 40) decodeClassic(frame, address)
                }
            }
        }
    }

    override fun pollOutput(): ProtocolOutput? = readings.removeFirstOrNull() ?: transport.pollOutput()

    private fun decodeClassic(frame: ByteArray, address: Int) {
        val battery = little16(frame, 14)
        if (battery !in 0..100) return
        val speed = if (address == 0x11) little16(frame, 34).toShort() / 100.0
                    else little16(frame, 16).toShort() / 1000.0
        val distance = (little16(frame, 20).toLong() or (little16(frame, 22).toLong() shl 16)) / 1000.0
        val voltage = if (address == 0x0a) 0.0 else little16(frame, 30) / 100.0
        val current = little16(frame, 32).toShort() / 100.0
        val temperature = little16(frame, 28).toShort() / 10.0
        if (speed !in -100.0..100.0 || current !in -300.0..300.0 || temperature !in -50.0..180.0) return
        if (address != 0x0a && voltage !in 20.0..100.0) return
        val model = when (address) { 0x11 -> "Ninebot One S2"; 0x0a -> "Ninebot Mini"; else -> "Ninebot One" }
        readings.addLast(ProtocolOutput.Telemetry(EUCData(
            speed = speed, voltage = voltage, current = current, temperature = temperature, batteryLevel = battery,
            distance = 0.0, totalDistance = distance, power = voltage * current, rawData = frame,
            timestamp = Clock.System.now().toEpochMilliseconds(), manufacturer = "Ninebot", model = model,
            rideTime = 0, isCharging = false
        )))
    }

    private fun zRequest(register: Int, count: Int): ByteArray =
        packet(byteArrayOf(1, 0x3e, 0x14, 1, register.toByte(), count.toByte()))

    private fun packet(body: ByteArray): ByteArray {
        val sum = checksum(body, 0, body.size)
        return (header + body + byteArrayOf(sum.toByte(), (sum shr 8).toByte())).also { if (isZ) crypt(it) }
    }

    private fun crypt(frame: ByteArray) {
        for (index in 3 until frame.size) {
            frame[index] = (frame[index].toInt() xor streamKey[(index - 3) % streamKey.size].toInt()).toByte()
        }
    }

    private fun little16(bytes: ByteArray, offset: Int): Int =
        unsigned(bytes[offset]) or (unsigned(bytes[offset + 1]) shl 8)

    private fun checksum(bytes: ByteArray, start: Int, end: Int): Int =
        ((start until end).sumOf { unsigned(bytes[it]) } xor 0xffff) and 0xffff

    private fun unsigned(byte: Byte) = byte.toInt() and 0xff

    private fun query(id: String, register: Int, interval: Long = 0, timeout: Long) =
        ProtocolQuerySpec(id, CommandType.CUSTOM, CommandValue.Integer(register),
                          intervalMs = interval, responseTimeoutMs = timeout, maxRetries = 0)

    companion object {
        private const val SESSION_KEY = 0x100
        private val CLASSIC_ADDRESSES = listOf(0x09, 0x11, 0x0a)
    }
}
