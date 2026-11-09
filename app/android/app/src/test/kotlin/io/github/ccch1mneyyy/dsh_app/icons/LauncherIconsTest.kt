package io.github.ccch1mneyyy.dsh_app.icons

import io.github.ccch1mneyyy.dsh_app.icons.LauncherIcons.MIST
import io.github.ccch1mneyyy.dsh_app.icons.LauncherIcons.MIST_ALT
import io.github.ccch1mneyyy.dsh_app.icons.LauncherIcons.ORIGINAL
import io.github.ccch1mneyyy.dsh_app.icons.LauncherIcons.STATE_DEFAULT
import io.github.ccch1mneyyy.dsh_app.icons.LauncherIcons.STATE_DISABLED
import io.github.ccch1mneyyy.dsh_app.icons.LauncherIcons.STATE_ENABLED
import org.junit.Assert.*
import org.junit.Test

class LauncherIconsTest {

    /** PackageManager's stored settings, as the plugin applies them (enable list, then disable). */
    private class Device {
        val states = HashMap<String, Int>()
        val writes = ArrayList<LauncherIcons.Step>()
        val stateOf: (String) -> Int = { states[it] ?: STATE_DEFAULT }

        fun on() = LauncherIcons.aliases.filter { LauncherIcons.isOn(it, stateOf(it.className)) }

        fun apply(plan: LauncherIcons.Plan, afterEach: () -> Unit = {}) {
            for (step in plan.enable + plan.disable) {
                states[step.className] = step.state
                writes += step
                afterEach()
            }
        }
    }

    private companion object {
        const val PKG = "io.github.ccch1mneyyy.dsh_app"
    }

    @Test fun aFreshInstallShowsMist() {
        val device = Device()
        assertEquals(listOf(ORIGINAL), device.on())
        assertEquals(MIST, LauncherIcons.current(device.stateOf, null))
        assertTrue(LauncherIcons.plan(MIST, device.stateOf, originalInUse = false).isEmpty)
    }

    private fun task(
        opened: LauncherIcons.Alias,
        activities: Int,
        viaOrigActivity: Boolean = false,
        id: Int = 1,
        top: String? = PKG,
    ) = LauncherIcons.Task(
        if (viaOrigActivity) listOf("$PKG.MainActivity", opened.className) else listOf(opened.className, null),
        activities,
        id,
        top,
    )

    private fun keep(
        tasks: List<LauncherIcons.Task>,
        visible: Boolean = true,
        resumed: Int? = null,
        interactive: Boolean = true,
        locked: Boolean = false,
    ) = LauncherIcons.keepOriginal(tasks, PKG, visible, resumed, interactive, locked)

    @Test fun customTabsAndDocumentPickersKeepTheirOriginalTaskEvenAfterHome() {
        val tasks = listOf(task(ORIGINAL, 2, top = "com.android.documentsui"))
        assertTrue(keep(tasks, visible = false))
        assertTrue(keep(tasks + task(MIST_ALT, 1, id = 2), resumed = 2))
        assertFalse(keep(listOf(task(ORIGINAL, 1)), visible = false))
    }

    @Test fun unknownTaskTopsAreProtectedUntilANewSnapshotIsAvailable() {
        assertTrue(keep(listOf(task(ORIGINAL, 1, top = null)), visible = false))
        assertFalse(keep(listOf(task(ORIGINAL, 0, top = null)), visible = false))
    }

    @Test fun aForeignActivityInAnotherTaskDoesNotBlockRetiringTheOriginal() {
        val tasks = listOf(task(ORIGINAL, 1), task(MIST_ALT, 2, id = 2, top = "com.android.documentsui"))
        assertFalse(keep(tasks, visible = false))
    }

    @Test fun screenOffAndLockAreNotHome() {
        val tasks = listOf(task(ORIGINAL, 1))
        assertTrue(keep(tasks, visible = false, interactive = false))
        assertTrue(keep(tasks, visible = false, locked = true))
        assertFalse(keep(tasks, visible = false, interactive = true, locked = false))
    }

    @Test fun nextLaunchWaitsForResumeBeforeRetiringAnOldTaskWithActivityRecords() {
        val tasks = listOf(task(ORIGINAL, 1), task(MIST_ALT, 1, id = 2))
        assertTrue(keep(tasks, resumed = null))
        assertTrue(keep(tasks, resumed = 1))
        assertFalse(keep(tasks, resumed = 2))
    }

    @Test fun everyOriginalTaskMustBeOutOfSightAndFreeOfForeignActivities() {
        val tasks = listOf(task(ORIGINAL, 1), task(ORIGINAL, 1, id = 2))
        assertTrue(keep(tasks, resumed = 2))
        assertFalse(keep(tasks, visible = false))
        assertTrue(keep(tasks + task(ORIGINAL, 2, id = 3, top = "com.android.chrome"), visible = false))
    }

    @Test fun destructionOrSwipingTheLastActivityAwayLeavesNoTaskToProtect() {
        assertFalse(keep(emptyList()))
        assertFalse(keep(listOf(task(ORIGINAL, 0))))
        assertFalse(keep(listOf(task(ORIGINAL, 0)), interactive = false, locked = true))
    }

    @Test fun onlyAnOpenTaskOpenedThroughTheOriginalKeepsItOn() {
        assertFalse(LauncherIcons.originalInUse(emptyList()))
        assertTrue(LauncherIcons.originalInUse(listOf(task(ORIGINAL, 1))))
        assertTrue(LauncherIcons.originalInUse(listOf(task(ORIGINAL, 2, viaOrigActivity = true))))
        assertFalse(LauncherIcons.originalInUse(listOf(task(MIST_ALT, 1))))
        assertFalse(LauncherIcons.originalInUse(listOf(task(ORIGINAL, 0))))
        assertFalse(LauncherIcons.originalInUse(listOf(task(ORIGINAL, 0), task(MIST_ALT, 1))))
    }

    @Test fun oldInstallsAndUnknownSavedValuesKeepTheirExistingIcon() {
        for (chosen in listOf(null, "", "rainbow", "night", "frost", "ink")) {
            val fresh = LauncherIcons.settlePlan(Device().stateOf, chosen, originalInUse = false)
            assertSame(ORIGINAL, fresh.target)
            assertTrue(fresh.isEmpty)
        }
    }

    @Test fun noEntryAtAllIsRepairedWithMist() {
        val device = Device()
        device.states[ORIGINAL.className] = STATE_DISABLED
        assertTrue(device.on().isEmpty())
        assertEquals(MIST, LauncherIcons.current(device.stateOf, null))
        device.apply(LauncherIcons.settlePlan(device.stateOf, null, originalInUse = false))
        assertEquals(listOf(MIST_ALT), device.on())
    }

    @Test fun userDisabledCountsAsOff() {
        val device = Device()
        device.states[MIST_ALT.className] = 3 // COMPONENT_ENABLED_STATE_DISABLED_USER
        assertFalse(LauncherIcons.isOn(MIST_ALT, 3))
        assertEquals(MIST, LauncherIcons.current(device.stateOf, MIST))
    }

    @Test(expected = IllegalArgumentException::class)
    fun unknownIconsAreRefused() {
        LauncherIcons.plan("rainbow", Device().stateOf, originalInUse = false)
    }

    @Test fun everyVariantHasExactlyOneAliasBesidesTheOriginal() {
        assertEquals(listOf(MIST), LauncherIcons.variants)
        for (variant in LauncherIcons.variants) {
            assertEquals(1, LauncherIcons.aliases.count { it.variant == variant && it !== ORIGINAL })
        }
        assertEquals(listOf(ORIGINAL), LauncherIcons.aliases.filter { it.enabledByManifest })
    }
}
