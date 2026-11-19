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
            Triple("ninebot", "$serial,$ffe1", "ninebot"),
            Triple("leaperkim", "$serial,$ffe1", "leaperkim"),
            Triple("nosfet", "$serial,$ffe1", "nosfet")
        )
        cases.forEach { (family, service, fixture) ->
            val session = assertNotNull(detection.select("", listOf(service), family))
            val readings = replay(session, fixture)
            assertTrue(readings.isNotEmpty(), "$fixture produced no telemetry")
            assertTrue(readings.all { reading -> reading.voltage in 30.0..250.0 && reading.speed.isFinite() }, fixture)
            if (fixture == "inmotion-p6") assertEquals(223.95, readings.first().voltage, 0.2)
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
