import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import "."
import "Inspect.js" as Inspect

Item {
    id: root
    property var shell: null
    readonly property string launcherPath: decodeURIComponent(Qt.resolvedUrl("../install-launcher").toString().replace(/^file:\/\//, ""))
    readonly property string launcherToken: Date.now().toString(36) + "-" + Math.random().toString(36).slice(2)
    property string launcherSource: ""
    Component.onDestruction: {
        launcherInstaller.running = false
        if (launcherSource)
            Quickshell.execDetached(["bash", "-c", launcherSource, launcherPath, "remove", launcherToken])
    }
    // Cache the helper before removal can delete the plugin folder. Detached
    // cleanup outlives this service; instance ownership makes reload ordering safe.
    FileView {
        path: root.launcherPath
        onLoaded: root.launcherSource = text()
    }
    Process {
        id: launcherInstaller
        command: ["bash", "-c", root.launcherSource, root.launcherPath, "install", root.launcherToken]
        running: root.launcherSource !== ""
        onExited: (code, status) => {
            if (code !== 0) console.warn("Aerial could not install its launcher entry (exit " + code + ").")
        }
    }
    function open() {
        if (window.visible) {
            for (const toplevel of ToplevelManager.toplevels.values)
                if (toplevel.title === window.title) toplevel.activate()
        }
        window.visible = true
        window.minimized = false
    }
    AerialWindow { id: window }
    function findItem(name) {
        return Inspect.find(window.contentItem, name)
    }
    IpcHandler {
        target: "io.github.dmitry-solomadin.aerial"
        function open(): void { root.open() }
        function close(): void { window.visible = false }
        // The player asks this when it starts, since only the shell knows the
        // language Omarchy is set to.
        function hourFormat(): string { return AerialStore.hour24 ? "24h" : "12h" }
        function status(): string {
            return JSON.stringify({
                open: window.visible,
                cli: AerialStore.cli,
                mode: AerialStore.mode,
                keptClip: AerialStore.keptClip,
                cycleCategory: AerialStore.cycleCategory,
                clock: AerialStore.clockOn,
                hour24: AerialStore.hour24,
                captions: AerialStore.captions,
                filter: AerialStore.filter,
                selected: AerialStore.selected,
                catalog: AerialStore.clips.length,
                visible: AerialStore.visibleClips.length,
                downloaded: AerialStore.downloadedCount,
                inRotation: AerialStore.cycleCount,
                usedBytes: AerialStore.usedBytes,
                freeBytes: AerialStore.freeBytes,
                activeDownloads: AerialStore.activeDownloads,
                catalogLoading: AerialStore.catalogLoading,
                message: AerialStore.message
            })
        }
        // Development: read or press the UI as text, so a change can be checked
        // without sending key presses to the desktop.
        function dump(name: string): string {
            const item = name ? root.findItem(name) : window.contentItem
            try { return item ? Inspect.text(item) : "no item " + name } catch (error) { return "dump failed: " + error }
        }
        function activate(name: string): string {
            const item = root.findItem(name)
            return !item ? "no item " + name : Inspect.activate(item) ? "activated " + name : name + " is not activatable"
        }
        // Picks an option in a SegmentedControl or Dropdown by its objectName.
        function choose(name: string, value: string): string {
            const item = root.findItem(name)
            const pick = item && (item.activated || item.changed)
            if (typeof pick !== "function") return "no choice " + name
            pick(value)
            return "chose " + value + " in " + name
        }
    }
}
