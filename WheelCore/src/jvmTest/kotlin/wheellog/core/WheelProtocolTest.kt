package wheellog.core

import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNotNull
import kotlin.test.assertNull
import kotlin.test.assertTrue

class WheelProtocolTest {
    private val detection = WheelDetection()
    private val serial = "0000ffe0-0000-1000-8000-00805f9b34fb"
    private val ffe1 = "0000ffe1-0000-1000-8000-00805f9b34fb"
    private val v1 = "$serial,0000ffe4-0000-1000-8000-00805f9b34fb,0000ffe9-0000-1000-8000-00805f9b34fb"
    private val uart = "6e400001-b5a3-f393-e0a9-e50e24dcca9e," +
        "6e400002-b5a3-f393-e0a9-e50e24dcca9e,6e400003-b5a3-f393-e0a9-e50e24dcca9e"

    @Test
    fun choosesAProtocolWithTheRightBluetoothChannel() {
        assertEquals("leaperkim", detection.hint("LK11513"))
        assertEquals("nosfet", detection.hint("NOSFET Aeon"))
        assertEquals("kingsong", detection.hint("KS-18XL"))
        assertEquals("inmotion", detection.hint("InMotion V8S"))
        assertNull(detection.select("speaker", emptyList(), "begode"))
        assertNull(detection.select("speaker", listOf(uart), "begode"))
        assertEquals("ninebot_z", detection.select("Ninebot Z10", listOf(uart), "")?.family)
        assertEquals("ninebot", detection.select("Ninebot One S2", listOf("$serial,$ffe1"), "")?.family)
    }

    @Test
    fun readsRecordedNotifications() {
        val cases = listOf(
            Triple("begode", "$serial,$ffe1", "begode"),
            Triple("extreme_bull", "$serial,$ffe1", "extreme-bull"),
            Triple("kingsong", "$serial,$ffe1", "kingsong"),
            Triple("inmotion", v1, "inmotion-v8s"),
            Triple("inmotion", uart, "inmotion-p6"),
            Triple("ninebot_z", uart, "ninebot"),
            Triple("leaperkim", "$serial,$ffe1", "leaperkim"),
            Triple("nosfet", "$serial,$ffe1", "nosfet")
        )
        cases.forEach { (family, service, fixture) ->
            val session = assertNotNull(detection.select("", listOf(service), family))
            val readings = replay(session, fixture)
            assertTrue(readings.isNotEmpty(), "$fixture produced no telemetry")
            assertTrue(readings.all { reading ->
                reading.voltage?.let { it in 30.0..250.0 } == true && reading.speed.isFinite()
            }, fixture)
            if (fixture == "inmotion-p6") assertEquals(223.95, assertNotNull(readings.first().voltage), 0.2)
        }
    }

    @Test
    fun recognizesNosfetTelemetryOnALeaperKimNamedBluetoothDevice() {
        val session = assertNotNull(detection.select("LK12345", listOf("$serial,$ffe1"), ""))
        assertTrue(replay(session, "nosfet").any { it.model.startsWith("Nosfet") })
    }

    @Test
    fun requestsInMotionV2TelemetryOnItsWriteChannel() {
        val session = assertNotNull(detection.select("InMotion P6", listOf(uart), ""))
        session.start(now = 0)
        session.tick(now = 1000)
        val write = assertNotNull(session.nextWrite())
        assertEquals("6e400002-b5a3-f393-e0a9-e50e24dcca9e", write.characteristic)
        assertTrue(write.data.isNotEmpty())
        session.finishWrite(accepted = true, now = 1000)
    }

    @Test
    fun requestsNinebotZTelemetryAfterReceivingBleVersion() {
        val session = assertNotNull(detection.select("Ninebot Z10", listOf(uart), ""))
        session.start(0)
        val first = assertNotNull(session.nextWrite())
        assertEquals(0x68, first.data[6].toInt() and 255)
        session.finishWrite(true, 0)
        session.receive("5aa502143e046801013dff".hexToByteArray(), 20)
        val registers = mutableListOf<Int>()
        for (now in 20L..2000L step 20) {
            session.tick(now)
            while (true) {
                val write = session.nextWrite() ?: break
                registers += write.data[6].toInt() and 255
                session.finishWrite(true, now)
            }
        }
        assertTrue(0xb0 in registers)
        assertTrue(0 !in registers)
    }

    @Test
    fun readsAClassicNinebotS2FrameAcrossNotifications() {
        val session = assertNotNull(detection.select("Ninebot One S2", listOf("$serial,$ffe1"), ""))
        val frame = ByteArray(40)
        "55aa220111b0".hexToByteArray().copyInto(frame)
        frame[14] = 85
        frame[30] = 0xee.toByte()
        frame[31] = 0x16
        frame[34] = 0xd2.toByte()
        frame[35] = 0x04
        val check = (2 until 38).sumOf { frame[it].toInt() and 255 } xor 0xffff
        frame[38] = check.toByte()
        frame[39] = (check shr 8).toByte()
        session.receive(frame.copyOfRange(0, 20), 0)
        assertNull(session.takeReading())
        session.receive(frame.copyOfRange(20, 40), 10)
        val reading = assertNotNull(session.takeReading())
        assertEquals("Ninebot One S2", reading.model)
        assertEquals(12.34, reading.speed)
        assertEquals(58.70, reading.voltage)
    }

    @Test
    fun recognizesXenoFirmwareMajorVersion() {
        val session = assertNotNull(detection.select("LK12345", listOf("$serial,$ffe1"), ""))
        val bytes = ByteArray(36)
        "dc5a5c202cec".hexToByteArray().copyInto(bytes)
        bytes[28] = 0xaf.toByte()
        bytes[29] = 0xc8.toByte()
        session.receive(bytes, 0)
        val reading = assertNotNull(session.takeReading())
        assertEquals("Nosfet Xeno", reading.model)
        assertEquals(115.0, reading.voltage)
    }

    private fun replay(session: WheelProtocol, fixture: String): List<WheelReading> = buildList {
        val resource = assertNotNull(javaClass.getResourceAsStream("/packets/$fixture.hex"))
        resource.bufferedReader().useLines { lines ->
            lines.forEachIndexed { index, hex ->
                session.receive(hex.hexToByteArray(), now = index.toLong() * 15)
                while (true) add(session.takeReading() ?: break)
            }
        }
    }
}
