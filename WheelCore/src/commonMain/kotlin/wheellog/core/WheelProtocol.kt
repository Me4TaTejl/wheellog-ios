package wheellog.core

import io.github.tritbool.euc.ble.core.EucClock
import io.github.tritbool.euc.ble.core.EucDateTime
import io.github.tritbool.euc.ble.core.EucRandom
import io.github.tritbool.euc.ble.core.EucUuid
import io.github.tritbool.euc.ble.core.InternalEucBleApi
import io.github.tritbool.euc.ble.core.NoOpLogger
import io.github.tritbool.euc.ble.models.EUCData
import io.github.tritbool.euc.ble.protocols.CommandSupport
import io.github.tritbool.euc.ble.protocols.CommandType
import io.github.tritbool.euc.ble.protocols.CommandValue
import io.github.tritbool.euc.ble.protocols.EucFingerprintDatabase
import io.github.tritbool.euc.ble.protocols.ExtremeBullSyncProtocol
import io.github.tritbool.euc.ble.protocols.GotwaySyncProtocol
import io.github.tritbool.euc.ble.protocols.InMotionSyncProtocol
import io.github.tritbool.euc.ble.protocols.KingsongSyncProtocol
import io.github.tritbool.euc.ble.protocols.LeaperkimSyncProtocol
import io.github.tritbool.euc.ble.protocols.NinebotSyncProtocol
import io.github.tritbool.euc.ble.protocols.NinebotZSyncProtocol
import io.github.tritbool.euc.ble.protocols.NosfetSyncProtocol
import io.github.tritbool.euc.ble.protocols.ProtocolOutput
import io.github.tritbool.euc.ble.protocols.SyncEucProtocol
import io.github.tritbool.euc.ble.session.PollingEngine
import io.github.tritbool.euc.ble.session.ProtocolSelector
import io.github.tritbool.euc.ble.session.ProtocolSession
import kotlinx.datetime.TimeZone
import kotlinx.datetime.toLocalDateTime
import kotlin.random.Random
import kotlin.time.Clock

private enum class Family(val key: String) {
    BEGODE("begode"), EXTREME_BULL("extreme_bull"), KINGSONG("kingsong"), INMOTION("inmotion"),
    NINEBOT("ninebot"), NINEBOT_Z("ninebot_z"), LEAPERKIM("leaperkim"), NOSFET("nosfet");

    fun decoder(): SyncEucProtocol = when (this) {
        BEGODE -> GotwaySyncProtocol(WheelClock)
        EXTREME_BULL -> ExtremeBullSyncProtocol(WheelClock)
        KINGSONG -> KingsongSyncProtocol(WheelClock, EucRandom { Random.nextInt(it) })
        INMOTION -> InMotionSyncProtocol(WheelClock)
        NINEBOT -> NinebotSyncProtocol(WheelClock)
        NINEBOT_Z -> NinebotZSyncProtocol(WheelClock)
        LEAPERKIM -> LeaperkimSyncProtocol(WheelClock)
        NOSFET -> NosfetSyncProtocol(WheelClock)
    }

    companion object {
        fun fromKey(key: String) = entries.firstOrNull { it.key == key }
    }
}

private object WheelClock : EucClock {
    override fun currentTimeMillis() = Clock.System.now().toEpochMilliseconds()

    override fun localDateTime(): EucDateTime {
        val local = Clock.System.now().toLocalDateTime(TimeZone.currentSystemDefault())
        return EucDateTime(local.year, local.month.ordinal + 1, local.day, local.hour, local.minute, local.second)
    }
}

class WheelDetection {
    fun hint(name: String): String? = namedFamily(name)?.key

    // Each row is a service UUID followed by its discovered characteristic UUIDs.
    @OptIn(InternalEucBleApi::class)
    fun select(name: String, services: List<String>, forced: String): WheelProtocol? {
        val snapshot = services.map { row ->
            val uuids = row.split(',').map(EucUuid::parse)
            ProtocolSelector.Service(uuids.first(), uuids.drop(1).toSet())
        }
        val available = snapshot.flatMap { it.characteristics }.toSet()
        val decoders = Family.entries.associateWith { it.decoder() }
        val selector = ProtocolSelector(decoders.values.toList(), NoOpLogger())
        val (fingerprint, _) = selector.byFingerprint(snapshot, EucFingerprintDatabase::getSignatures)
        val named = namedFamily(name)
        val matched = decoders.entries.firstOrNull { it.value === fingerprint }?.key
        val candidates = listOfNotNull(named, matched)
        val family = if (forced.isNotEmpty()) Family.fromKey(forced) else candidates.firstOrNull {
            decoders.getValue(it).getCandidateDataCharacteristicUUIDs().any { uuid -> uuid in available }
        }
        val decoder = decoders[family] ?: return null
        if (decoder.getCandidateDataCharacteristicUUIDs().none { it in available }) return null
        if (decoder is InMotionSyncProtocol) {
            val v1 = EucUuid.parse("0000ffe4-0000-1000-8000-00805f9b34fb")
            // For legacy, let the decoder see the first V1 frame after its startup query.
            if (v1 !in available) decoder.setDialect(2)
        }
        return WheelProtocol(checkNotNull(family).key, decoder)
    }

    private fun namedFamily(name: String): Family? {
        val label = name.trim().lowercase()
        return when {
            label.hasAny("nosfet", "apex", "aero", "aeon", "xeno") -> Family.NOSFET
            label.startsWith("lk") || label.hasAny("leaperkim", "veteran", "sherman", "patton", "lynx", "oryx") ->
                Family.LEAPERKIM
            label.startsWith("ks-") || label.startsWith("ks_") || label.hasAny("kingsong", "king song") ->
                Family.KINGSONG
            label.hasAny("extreme bull", "extremebull", "commander", "eb rocket") || label.startsWith("eb-") ->
                Family.EXTREME_BULL
            label.startsWith("gw") || label.hasAny("begode", "gotway", "mten", "msuper", "mcm", "tesla", "nikola") ->
                Family.BEGODE
            label.startsWith("nbz") || label.hasAny("ninebot z", "ninebot_z", "one z") -> Family.NINEBOT_Z
            label.hasAny("ninebot", "segway", "one e+", "one s2") || label.startsWith("nb-") -> Family.NINEBOT
            label.hasAny("inmotion", "in motion", "solowheel", "glide") ||
                Regex("^(?:v(?:5|6|8|9|10|11|12|13|14)|p6)(?:$|[-_ 0-9a-z])").containsMatchIn(label) ->
                Family.INMOTION
            else -> null
        }
    }

    private fun String.hasAny(vararg tokens: String) = tokens.any { contains(it) }
}

class WheelReading internal constructor(data: EUCData, phaseOnly: Boolean, begodeBatteryCurrent: Boolean?) {
    val model = data.model
    val version = data.firmwareVersion
    val speed = data.speed
    val voltage = data.voltage
    val battery = data.batteryLevel.toDouble().takeIf { it in 0.0..100.0 }
    val temperature = data.temperature
    val motorTemperature = data.motorTemperature
    val pwm = data.pwm?.takeIf {
        it in 0.0..100.0 && (!phaseOnly || (data.rawData[3].toInt() and 0xff) >= 36)
    }
    // WheelLog.Android documents LeaperKim's wire field in tenths of a phase amp.
    val phaseCurrent = if (phaseOnly) data.current * 10 else data.phaseCurrent
    val current = when {
        phaseOnly -> pwm?.let { data.current * 10 * it / 100 }
        begodeBatteryCurrent == false -> pwm?.let { data.current * it / 100 }
        else -> data.current
    }
    val power = current?.let { data.voltage * it }
    val trip = data.wheelDistance ?: data.distance
    val odometer = data.totalDistance
    val pedalMode = data.pedalsMode
}

class WheelPacket internal constructor(
    val data: ByteArray,
    val characteristic: String,
    val writeType: String,
    internal val token: Long? = null
)

/** A single BLE connection. The Swift transport invokes this class on its main queue. */
class WheelProtocol internal constructor(val family: String, private var decoder: SyncEucProtocol) {
    private var session = ProtocolSession(decoder)
    private var polling = PollingEngine(decoder.manufacturer)
    private val writes = ArrayDeque<WheelPacket>()
    private val readings = ArrayDeque<WheelReading>()
    private var seenBegodeBatteryCurrent = false

    val notificationUUIDs: List<String> get() = decoder.getCandidateDataCharacteristicUUIDs().map { it.value }
    val writeUUID: String get() = decoder.getWriteCharacteristicUUID().value
    val hasHeadlight: Boolean get() = supports(CommandType.LIGHT_ON) && supports(CommandType.LIGHT_OFF)
    val hasPedalModes: Boolean get() = supports(CommandType.SET_PEDALS_MODE)

    fun start(now: Long) {
        polling.start(decoder.getPollingPlan(), now)
        tick(now)
    }

    fun receive(bytes: ByteArray, now: Long) {
        polling.onResponse(now) { decoder.matchesQueryResponse(it, bytes) }
        session.onNotification(bytes, now)
        drain(now)
        tick(now)
    }

    fun tick(now: Long) {
        session.advance(now)
        drain(now)
        polling.tick(decoder.getPollingPlan(), now)
        while (true) {
            val output = polling.pollOutput() ?: break
            if (output is PollingEngine.Output.Query) {
                val data = decoder.createCommand(output.spec.commandType, output.spec.value)
                if (data.isEmpty()) polling.onFailed(output.token, now, unsupported = true)
                else writes.addLast(packet(data, output.token))
                session.afterInput(now)
            }
        }
        drain(now)
    }

    fun takeReading(): WheelReading? = readings.removeFirstOrNull()
    fun nextWrite(): WheelPacket? = writes.firstOrNull()

    fun finishWrite(accepted: Boolean, now: Long) {
        val write = writes.removeFirstOrNull() ?: return
        if (accepted) {
            decoder.onCommandSubmitted(write.data)
            write.token?.let { polling.onAccepted(it, now) }
            session.afterInput(now)
            drain(now)
        } else {
            write.token?.let { polling.onFailed(it, now) }
        }
    }

    fun requestLight(enabled: Boolean, now: Long): Boolean =
        request(if (enabled) CommandType.LIGHT_ON else CommandType.LIGHT_OFF, CommandValue.None, now)

    fun requestPedals(mode: Int, now: Long): Boolean =
        request(CommandType.SET_PEDALS_MODE, CommandValue.Integer(mode), now)

    private fun request(command: CommandType, value: CommandValue, now: Long): Boolean {
        if (!supports(command) || writes.isNotEmpty()) return false
        val data = decoder.createCommand(command, value)
        if (data.isEmpty() || !decoder.canSendCommand(data)) return false
        writes.addLast(packet(data))
        session.afterInput(now)
        drain(now)
        return true
    }

    private fun supports(command: CommandType) = decoder.getCommandSupport(command) == CommandSupport.SUPPORTED

    private fun packet(data: ByteArray, token: Long? = null) =
        WheelPacket(data, decoder.getWriteCharacteristicUUID().value, decoder.preferredWriteType.name, token)

    private fun drain(now: Long) {
        while (true) {
            when (val output = session.pollOutput() ?: return) {
                is ProtocolOutput.Telemetry -> {
                    val data = output.data
                    if (decoder is LeaperkimSyncProtocol && decoder !is NosfetSyncProtocol &&
                        data.firmwareVersion?.substringBefore('.')?.toIntOrNull()?.let { it in 42..44 } == true
                    ) {
                        decoder = NosfetSyncProtocol(WheelClock)
                        session = ProtocolSession(decoder)
                        polling = PollingEngine(decoder.manufacturer)
                        writes.clear()
                        session.onNotification(data.rawData, now)
                    } else if (data.voltage in 15.0..300.0 && data.speed in -250.0..250.0) {
                        readings.addLast(mapReading(data))
                    }
                }
                is ProtocolOutput.Write -> writes.addLast(packet(output.payload))
                else -> Unit
            }
        }
    }

    @OptIn(InternalEucBleApi::class)
    private fun mapReading(data: EUCData): WheelReading {
        val gotway = decoder is GotwaySyncProtocol
        if (gotway && data.frameType == "Type 7") seenBegodeBatteryCurrent = true
        return WheelReading(data, decoder is LeaperkimSyncProtocol,
                            seenBegodeBatteryCurrent.takeIf { gotway })
    }
}
