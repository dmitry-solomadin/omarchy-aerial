pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons as Commons
import "../Library.js" as Library

// Everything the window shows and does. It lives in the shell rather than the
// window, so downloads carry on after the window closes. All network work and
// file deletion happens in bin/aerial, reached with argv and never a shell string.
QtObject {
    id: root

    readonly property string home: Quickshell.env("HOME")
    readonly property string dataDir: (Quickshell.env("XDG_DATA_HOME") || home + "/.local/share") + "/aerial"
    readonly property string configPath: (Quickshell.env("XDG_CONFIG_HOME") || home + "/.config") + "/aerial/aerial.conf"
    readonly property string thumbnailDir: (Quickshell.env("XDG_CACHE_HOME") || home + "/.cache") + "/aerial/thumbnails"
    readonly property string cli: Quickshell.env("AERIAL_CLI") || decodeURIComponent(Qt.resolvedUrl("../../bin/aerial").toString().replace(/^file:\/\//, ""))

    readonly property int maxParallelDownloads: 2
    readonly property int catalogMaxAgeSeconds: 7 * 24 * 3600

    property Commons.Translations strings: Commons.Translations { directory: Qt.resolvedUrl("../i18n") }

    // What is known about the library.
    property var clips: []
    property var onDisk: ({})
    property var thumbnails: ({})
    property var transfers: ({})
    property real freeBytes: 0
    property bool catalogLoading: false
    property string message: ""
    // Errors are told apart from plain news, which should not look like a fault.
    property bool messageIsError: true

    // Settings, mirrored from aerial.conf.
    property string mode: "cycle"
    property string keptClip: ""
    property string cycleCategory: ""
    property bool clockOn: true
    // 12 or 24 hours follows the language Omarchy is set to, as its own panels do.
    readonly property bool hour24: Library.usesTwentyFourHour(Qt.locale(Commons.I18n.formatLocale).timeFormat(Locale.ShortFormat))
    property bool captions: true

    // The lock screen, as bin/aerial reports it.
    property bool lockAvailable: false
    property bool lockVideoOn: false

    // The window.
    property bool windowOpen: false
    property bool windowMinimized: false
    property string filter: "all"
    property string selected: ""

    readonly property var visibleClips: Library.visibleClips(clips, filter, onDisk)
    readonly property int downloadedCount: Library.cycleCount(clips, "", onDisk)
    readonly property int cycleCount: Library.cycleCount(clips, cycleCategory, onDisk)
    readonly property real usedBytes: Library.usedBytes(onDisk)
    readonly property int activeDownloads: Object.keys(transfers).length
    readonly property bool keptReady: keptClip !== "" && onDisk[keptClip] !== undefined
    readonly property var keptEntry: clips.find(clip => clip.name === keptClip) || null

    function isDownloaded(name) { return onDisk[name] !== undefined }
    function transfer(name) { return transfers[name] || null }
    function thumbnail(name) {
        const path = Library.thumbnailPath(name, onDisk[name] !== undefined, thumbnails, thumbnailDir)
        return path ? Commons.Util.fileUrl(path) : ""
    }
    function formatBytes(bytes) {
        const gigabyte = bytes >= 1e9
        return strings.t(gigabyte ? "size.gb" : "size.mb").arg(Commons.I18n.formatNumber(bytes / (gigabyte ? 1e9 : 1e6), gigabyte ? 1 : 0))
    }

    // ---- settings

    property bool configLoaded: false
    property FileView configFile: FileView {
        path: root.configPath
        watchChanges: true
        atomicWrites: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: { root.configLoaded = true; root.applySettings(Library.parseConfig(text())) }
        onLoadFailed: { root.configLoaded = true; root.applySettings({}) }
    }
    function applySettings(values) {
        const settings = Library.settingsFrom(values)
        mode = settings.mode
        keptClip = settings.clip
        cycleCategory = settings.cycleCategory
        clockOn = settings.clockOn
        captions = settings.captions
    }
    function save(values) {
        // Saving before the file is read would write over its comments.
        if (!configLoaded) { showError(strings.t("error.settingsNotReady")); return }
        configFile.setText(Library.mergeConfig(configFile.text(), values))
    }
    function showError(text) { message = text; messageIsError = true }
    function setCycleCategory(category) { cycleCategory = category; save({categories: category}) }
    function setClockOn(on) { clockOn = on; save({clock: on ? "on" : "off"}) }
    function setCaptions(value) { captions = value; save({captions: value ? "yes" : "no"}) }
    function cycle() { mode = "cycle"; save({mode: "cycle"}); lockSync.restart() }
    // Keeping a clip that is not here yet means wanting it here. The screensaver
    // cycles through what is on disk until it arrives.
    function keep(name) {
        if (!Library.validName(name)) return
        mode = "one"
        keptClip = name
        save({mode: "one", clip: name})
        if (!isDownloaded(name)) download(name)
        lockSync.restart()
    }
    function keepSomething() {
        const name = Library.clipToKeep(selected, keptClip, clips, onDisk)
        if (name) keep(name)
        else showError(strings.t("error.nothingToKeep"))
    }

    // ---- the catalogue and what is on disk

    property FileView catalogFile: FileView {
        path: root.dataDir + "/catalog.json"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: root.clips = Library.reuseClips(root.clips, Library.parseCatalog(text()))
    }
    property bool libraryChecked: false
    property bool libraryPending: false
    property Process libraryProcess: Process {
        command: [root.cli, "fetch", "--library"]
        stdout: StdioCollector { onStreamFinished: root.applyLibrary(text) }
        onExited: if (root.libraryPending) { root.libraryPending = false; root.refreshLibrary() }
    }
    function refreshLibrary() {
        if (libraryProcess.running) libraryPending = true
        else libraryProcess.running = true
    }
    function applyLibrary(text) {
        const report = Library.parseLibrary(text)
        if (!report) return
        onDisk = report.clips
        thumbnails = report.thumbnails
        freeBytes = report.free
        // The first look each session decides what the network is needed for.
        if (libraryChecked) return
        libraryChecked = true
        if (report.catalogAge === null || report.catalogAge > catalogMaxAgeSeconds) refreshCatalog()
        else fetchThumbnails("")
    }
    // Catches clips added or removed from the command line.
    property Timer libraryPoll: Timer {
        interval: 10000
        repeat: true
        running: root.windowOpen && !root.windowMinimized
        onTriggered: { root.refreshLibrary(); root.refreshLock() }
    }
    property Timer libraryDebounce: Timer {
        interval: 400
        onTriggered: root.refreshLibrary()
    }
    function windowShown() {
        windowOpen = true
        refreshLibrary()
        refreshLock()
    }

    // ---- the lock screen

    property bool lockPending: false
    property Process lockProcess: Process {
        command: [root.cli, "lock", "status"]
        stdout: StdioCollector {
            onStreamFinished: {
                const status = Library.parseLockStatus(text)
                root.lockAvailable = status.available
                root.lockVideoOn = status.enabled
            }
        }
        onExited: if (root.lockPending) { root.lockPending = false; root.refreshLock() }
    }
    function refreshLock() {
        if (lockProcess.running) lockPending = true
        else lockProcess.running = true
    }
    function setLockVideo(on) {
        lockVideoOn = on
        runCommand([cli, "lock", on ? "on" : "off"], null, ok => {
            if (!ok) showError(strings.t("error.lock"))
            refreshLock()
        })
    }
    // Waits a moment, because bin/aerial reads the settings file this just saved.
    property Timer lockSync: Timer {
        interval: 400
        onTriggered: if (root.lockVideoOn) root.runCommand([root.cli, "lock", "sync"], null, () => root.refreshLock())
    }

    // ---- running bin/aerial

    property Component jobComponent: Component {
        Process {
            id: job
            property var handleEvent: null
            property var handleFinish: null
            property string failure: ""
            property bool settled: false
            function settle() {
                if (settled) return
                settled = true
                const finish = handleFinish
                const reason = failure
                const ok = exitedCleanly
                Qt.callLater(() => job.destroy())
                if (finish) finish(ok, reason)
            }
            property bool exitedCleanly: false
            stdout: SplitParser {
                onRead: line => {
                    const event = Library.parseEvent(line)
                    if (!event) return
                    if (event.event === "error") job.failure = String(event.message || "").slice(0, 300)
                    if (job.handleEvent) job.handleEvent(event)
                }
            }
            onExited: (code, status) => { exitedCleanly = code === 0; settle() }
            // A program that never starts reports no exit.
            onRunningChanged: if (!running) Qt.callLater(settle)
        }
    }
    function runCommand(command, handleEvent, handleFinish) {
        const job = jobComponent.createObject(root, {
            command: command,
            handleEvent: handleEvent,
            handleFinish: handleFinish
        })
        job.running = true
        return job
    }
    function runFetch(args, handleEvent, handleFinish) {
        return runCommand([cli, "fetch"].concat(args).concat(["--json"]), handleEvent, handleFinish)
    }

    function refreshCatalog() {
        if (catalogLoading) return
        catalogLoading = true
        runFetch(["--catalog"], null, ok => {
            catalogLoading = false
            // Clips already on disk keep working, so this only limits browsing.
            if (ok) { catalogFile.reload(); fetchThumbnails("") }
            else showError(strings.t("error.catalog"))
        })
    }

    // Thumbnails are a nicety: cards show a plain tile without them, which is not
    // worth interrupting anyone over.
    property var thumbnailJob: null
    property var thumbnailBacklog: []
    function fetchThumbnails(name) {
        if (thumbnailJob) { thumbnailBacklog = thumbnailBacklog.concat([name]); return }
        thumbnailJob = runFetch(name ? ["--thumbnails", "--clip", name] : ["--thumbnails"], event => {
            if (event.event === "thumbnail") libraryDebounce.restart()
        }, () => {
            thumbnailJob = null
            libraryDebounce.restart()
            if (thumbnailBacklog.length) {
                const next = thumbnailBacklog[0]
                thumbnailBacklog = thumbnailBacklog.slice(1)
                fetchThumbnails(next)
            }
        })
    }

    // ---- downloads

    property var queue: []
    property var running: ({})
    function setTransfer(name, value) {
        const next = Object.assign({}, transfers)
        if (value) next[name] = value
        else delete next[name]
        transfers = next
    }
    function download(name) {
        if (!Library.validName(name) || isDownloaded(name) || transfers[name]) return
        queue = queue.concat([name])
        setTransfer(name, {state: "queued", progress: 0})
        pump()
    }
    function pump() {
        while (Object.keys(running).length < maxParallelDownloads && queue.length) {
            const name = queue[0]
            queue = queue.slice(1)
            startDownload(name)
        }
    }
    function startDownload(name) {
        setTransfer(name, {state: "downloading", progress: 0})
        const job = runFetch(["--clip", name], event => {
            if (event.event === "progress" && event.total > 0)
                setTransfer(name, {state: "downloading", progress: event.bytes / event.total})
        }, (ok, failure) => {
            const entry = running[name]
            const next = Object.assign({}, running)
            delete next[name]
            running = next
            setTransfer(name, null)
            if (entry && entry.cancelled) runFetch(["--delete", name], null, null)
            else if (ok) { fetchThumbnails(name); lockSync.restart() }
            else {
                const clip = clips.find(item => item.name === name)
                showError(strings.t("error.download").arg(clip ? clip.label : name).arg(failure || strings.t("error.unknown")))
            }
            refreshLibrary()
            pump()
        })
        const next = Object.assign({}, running)
        next[name] = {job: job, cancelled: false}
        running = next
    }
    function cancel(name) {
        if (queue.indexOf(name) >= 0) {
            queue = queue.filter(item => item !== name)
            setTransfer(name, null)
        } else if (running[name]) {
            running[name].cancelled = true
            running[name].job.running = false
        }
    }
    function remove(name) {
        if (!Library.validName(name)) return
        cancel(name)
        if (!isDownloaded(name)) return
        const clip = clips.find(item => item.name === name)
        const wasKept = mode === "one" && keptClip === name
        // Show it gone at once. The next report corrects this if the delete fails.
        const next = Object.assign({}, onDisk)
        delete next[name]
        onDisk = next
        if (wasKept) {
            mode = "cycle"
            keptClip = ""
            save({mode: "cycle", clip: ""})
            message = strings.t("message.keptDeleted").arg(clip ? clip.label : name)
            messageIsError = false
        }
        runFetch(["--delete", name], null, ok => {
            if (!ok) showError(strings.t("error.delete").arg(clip ? clip.label : name))
            refreshLibrary()
            lockSync.restart()
        })
    }

    // ---- the screensaver

    function start() {
        if (downloadedCount === 0) { showError(strings.t("error.nothingToPlay")); return }
        Quickshell.execDetached([cli, "start", "force"])
    }
    function preview(name) {
        if (isDownloaded(name)) Quickshell.execDetached([cli, "start", "force", "--clip", name])
    }
}
