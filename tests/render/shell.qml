import QtQuick
import Quickshell
import QtTest
import "Plugin"
import "Plugin/Inspect.js" as Inspect

// Walks the real window through its states and saves a picture of each, with no
// window on the desktop and no input sent to it. See tests/render/run.
ShellRoot {
    id: root
    readonly property string out: Quickshell.env("SHOTS")
    // SHORT=1 starts the window at a laptop's size, in the taller keep-one layout.
    readonly property bool short: Quickshell.env("SHORT") === "1"
    AerialWindow {
        id: window
        visible: true
        Component.onCompleted: if (root.short) { implicitWidth = 1000; implicitHeight = 560 }
    }

    // Pointer events for the offscreen window only. They can't reach the desktop.
    TestEvent { id: pointer }
    function move(item, x, y) { pointer.mouseMove(item, x, y, -1, Qt.NoButton, Qt.NoModifier) }

    // Samples for a second after the pointer lands. A flicker shows up as changes.
    property var sampling: null
    Timer {
        id: sampler
        interval: 16
        repeat: true
        onTriggered: {
            const probe = root.sampling
            const now = probe.read()
            if (now !== probe.last) { probe.changes++; probe.last = now }
            if (--probe.left > 0) return
            stop()
            console.log("hover " + probe.name + ": ended " + now + ", changes while settled " + probe.changes)
            probe.done()
        }
    }
    function sample(name, read, done) {
        sampling = {name: name, read: read, last: read(), changes: 0, left: 60, done: done}
        sampler.restart()
    }
    function find(name) { return Inspect.find(window.contentItem, name) }
    function hoverTests(finished) {
        // The pointer goes onto a card that isn't selected, then onto its button.
        const clip = AerialStore.visibleClips.find(clip => AerialStore.isDownloaded(clip.name) && clip.name !== AerialStore.selected)
        const card = find("clip_" + clip.name)
        const button = find("preview_" + clip.name)
        const actions = find("actions_" + clip.name)
        const state = () => "shown=" + (actions.opacity > 0) + " buttonHovered=" + button.hovered
        console.log("hover before: " + state())
        move(card, card.width / 2, 40)
        sample("on the card", state, () => {
            const point = button.mapToItem(card, button.width / 2, button.height / 2)
            move(card, point.x, point.y)
            sample("on its button", state, () => {
                // Hovering the active tab must not change its color, and other tabs must.
                const active = find("filter_" + AerialStore.filter)
                const other = find("filter_" + (AerialStore.filter === "Space" ? "Cities" : "Space"))
                const activeBefore = String(active.background.color)
                const otherBefore = String(other.background.color)
                move(active, active.width / 2, active.height / 2)
                settleThen(() => {
                    console.log("hover active tab: fill " + activeBefore + " -> " + active.background.color + " hovered=" + active.hovered)
                    move(other, other.width / 2, other.height / 2)
                    settleThen(() => {
                        console.log("hover other tab: fill " + otherBefore + " -> " + other.background.color + " hovered=" + other.hovered)
                        finished()
                    })
                })
            })
        })
    }
    function settleThen(next) { pause.next = next; pause.restart() }
    Timer { id: pause; property var next: null; interval: 200; onTriggered: next() }

    property int step: 0
    property var steps: short ? shortSteps : fullSteps
    readonly property var shortSteps: [
        {name: "8-short-window", act: () => {}, first: () => { AerialStore.keep(Object.keys(AerialStore.onDisk)[0]) }, report: () => {
            const target = find("windowContent")
            const start = find("startScreensaver")
            console.log("fits " + target.width + "x" + target.height + ": start bottom " + Math.round(start.mapToItem(target, 0, start.height).y)
                + ", columns " + find("clipGrid").columns)
        }}
    ]
    readonly property var fullSteps: [
        {name: "1-all", act: () => {}, report: () => {
            console.log("fits nothing selected at first: currentIndex=" + find("clipGrid").currentIndex + " selected=[" + AerialStore.selected + "] clockOn=" + AerialStore.clockOn + " hour24=" + AerialStore.hour24)
        }},
        {name: "2-downloaded", act: () => { AerialStore.filter = "downloaded" }},
        {name: "3-keep", act: () => { AerialStore.keep(AerialStore.visibleClips[1].name) }},
        {name: "3b-hover", hover: true, act: () => { AerialStore.cycle() }},
        {name: "4-downloading", act: () => {
            AerialStore.cycle()
            AerialStore.filter = "all"
            for (const clip of AerialStore.clips.filter(clip => !AerialStore.isDownloaded(clip.name)).slice(0, 3))
                AerialStore.download(clip.name)
        }},
        {name: "5-category", act: () => { AerialStore.setCycleCategory("Space"); AerialStore.filter = "Space" }},
        {name: "6-kept-deleted", act: () => {
            AerialStore.filter = "downloaded"
            const name = Object.keys(AerialStore.onDisk)[0]
            AerialStore.keep(name)
            AerialStore.remove(name)
        }},
        {name: "6b-clock-off", act: () => {
            find("clockToggle").activate()
        }, report: () => {
            console.log("fits clock toggle: clockOn=" + AerialStore.clockOn)
        }},
        {name: "6c-lock-on", act: () => {
            AerialStore.message = ""
            find("lockVideoToggle").activate()
        }, report: () => {
            console.log("fits lock section shown=" + find("lockSection").visible + " toggle on=" + find("lockVideoToggle").checked)
        }},
    ]

    function capture() {
        const current = steps[step]
        if (current.first && !current.prepared) {
            current.prepared = true
            current.first()
            settle.restart()
            return
        }
        if (current.hover && !current.tested) {
            current.tested = true
            hoverTests(capture)
            return
        }
        const target = Inspect.find(window.contentItem, "windowContent")
        target.grabToImage(result => {
            result.saveToFile(out + "/" + current.name + ".png")
            if (current.report) current.report()
            console.log("shot " + current.name + ": mode=" + AerialStore.mode + " kept=" + AerialStore.keptClip
                + " category=" + AerialStore.cycleCategory + " visible=" + AerialStore.visibleClips.length
                + " onDisk=" + Object.keys(AerialStore.onDisk).length + " active=" + AerialStore.activeDownloads
                + " message=" + AerialStore.message)
            step++
            if (step >= steps.length) Qt.quit()
            else { steps[step].act(); settle.restart() }
        })
    }
    // Long enough for the fetcher's report and for thumbnails to decode.
    Timer { id: settle; interval: 1500; running: true; onTriggered: root.capture() }
}
