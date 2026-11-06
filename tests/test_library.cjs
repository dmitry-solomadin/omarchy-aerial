// Runs the rules in qml/Library.js without a QML engine: node tests/test_library.cjs
const assert = require("node:assert")
const fs = require("node:fs")
const path = require("node:path")
const vm = require("node:vm")

const source = fs.readFileSync(path.join(__dirname, "../qml/Library.js"), "utf8")
const context = {}
vm.runInNewContext(source, context)
const lib = context
const plain = value => JSON.parse(JSON.stringify(value))

const catalog = JSON.stringify({clips: {
    "sea-1.mov": {label: "Sea", category: "Space", size: 100},
    "city-2.mov": {label: "City", category: "Cities", size: 200},
    "../../evil.mov": {label: "Evil", category: "Cities", size: 1},
    "UPPER.mov": {label: "Upper", category: "Cities", size: 1}
}})
const clips = lib.parseCatalog(catalog)

const tests = {
    "unsafe clip names are dropped"() {
        assert.deepStrictEqual(plain(clips.map(clip => clip.name)), ["city-2.mov", "sea-1.mov"])
        for (const bad of ["../x.mov", "a/b.mov", ".mov", "x.mov.part", "x.mp4", ""]) assert.strictEqual(lib.validName(bad), false, bad)
    },
    "broken catalogues give no clips"() {
        for (const bad of ["", "not json", "null", "[]", "{\"clips\": 3}"]) assert.strictEqual(lib.parseCatalog(bad).length, 0, bad)
    },
    "long labels are cut"() {
        const long = JSON.stringify({clips: {"a.mov": {label: "x".repeat(500)}}})
        assert.strictEqual(lib.parseCatalog(long)[0].label.length, 120)
    },
    "markup in a label stays text for the PlainText labels"() {
        const hostile = JSON.stringify({clips: {"a.mov": {label: "<img src=x>"}}})
        assert.strictEqual(lib.parseCatalog(hostile)[0].label, "<img src=x>")
    },
    "refreshing keeps unchanged clip objects"() {
        const next = lib.parseCatalog(catalog)
        const reused = lib.reuseClips(clips, next)
        assert.strictEqual(reused[0], clips[0])
        const changed = lib.reuseClips(clips, lib.parseCatalog(catalog.replace('"size":100', '"size":999')))
        assert.notStrictEqual(changed[1], clips[1])
    },
    "tabs filter by disk or category"() {
        const onDisk = {"sea-1.mov": 100}
        assert.strictEqual(lib.visibleClips(clips, "all", onDisk).length, 2)
        assert.deepStrictEqual(plain(lib.visibleClips(clips, "downloaded", onDisk).map(c => c.name)), ["sea-1.mov"])
        assert.deepStrictEqual(plain(lib.visibleClips(clips, "Cities", onDisk).map(c => c.name)), ["city-2.mov"])
    },
    "rotation counts what is on disk in the category"() {
        const onDisk = {"sea-1.mov": 100, "city-2.mov": 200}
        assert.strictEqual(lib.cycleCount(clips, "", onDisk), 2)
        assert.strictEqual(lib.cycleCount(clips, "Cities", onDisk), 1)
        assert.strictEqual(lib.cycleCount(clips, "Cities", {"sea-1.mov": 100}), 0)
        assert.strictEqual(lib.usedBytes(onDisk), 300)
    },
    "saving keeps comments and unknown keys"() {
        const before = "# a comment\nmode=cycle\n\nfont=Adwaita Sans\n"
        assert.strictEqual(lib.mergeConfig(before, {mode: "one", clip: "x.mov"}),
            "# a comment\nmode=one\n\nfont=Adwaita Sans\nclip=x.mov\n")
        assert.strictEqual(lib.mergeConfig("", {mode: "one"}), "mode=one\n")
    },
    "parsing matches what the Lua reader accepts"() {
        const values = plain(lib.parseConfig("# mode=wrong\n  clock = 24h  \ncaptions=no\nfont=Adwaita Sans\n"))
        assert.deepStrictEqual(values, {clock: "24h", captions: "no", font: "Adwaita Sans"})
    },
    "settings fall back to safe values"() {
        const bad = plain(lib.settingsFrom({mode: "nonsense", clip: "../x.mov", clock: "13h", captions: "no"}))
        assert.deepStrictEqual(bad, {mode: "cycle", clip: "", cycleCategory: "", clockOn: true, captions: false})
        assert.strictEqual(lib.settingsFrom({clock: "off"}).clockOn, false)
        for (const on of ["on", "12h", "24h", undefined]) assert.strictEqual(lib.settingsFrom({clock: on}).clockOn, true, String(on))
        assert.strictEqual(lib.settingsFrom({}).captions, true)
        assert.strictEqual(lib.settingsFrom({categories: "Space,Cities"}).cycleCategory, "")
        assert.strictEqual(lib.settingsFrom({categories: "Space"}).cycleCategory, "Space")
    },
    "keep prefers the selected clip, then the kept one, then the first on disk"() {
        const onDisk = {"sea-1.mov": 1, "city-2.mov": 2}
        assert.strictEqual(lib.clipToKeep("sea-1.mov", "city-2.mov", clips, onDisk), "sea-1.mov")
        assert.strictEqual(lib.clipToKeep("missing.mov", "sea-1.mov", clips, onDisk), "sea-1.mov")
        assert.strictEqual(lib.clipToKeep("", "", clips, onDisk), "city-2.mov")
        assert.strictEqual(lib.clipToKeep("sea-1.mov", "", clips, {}), "")
    },
    "thumbnails prefer the sharp frame only for clips on disk"() {
        const thumbs = {"a.mov.jpg": true, "a.mov.png": true, "b.mov.png": true}
        assert.strictEqual(lib.thumbnailPath("a.mov", true, thumbs, "/t"), "/t/a.mov.jpg")
        assert.strictEqual(lib.thumbnailPath("a.mov", false, thumbs, "/t"), "/t/a.mov.png")
        assert.strictEqual(lib.thumbnailPath("b.mov", true, thumbs, "/t"), "/t/b.mov.png")
        assert.strictEqual(lib.thumbnailPath("c.mov", true, thumbs, "/t"), "")
    },
    "a time format with no AM/PM marker is a 24-hour clock"() {
        assert.strictEqual(lib.usesTwentyFourHour("h:mm AP"), false)
        assert.strictEqual(lib.usesTwentyFourHour("h:mm ap"), false)
        assert.strictEqual(lib.usesTwentyFourHour("HH:mm"), true)
        assert.strictEqual(lib.usesTwentyFourHour("HH:mm 'Uhr'"), true)
        assert.strictEqual(lib.usesTwentyFourHour("H.mm 'a'"), true)
    },
    "an unreadable lock report means no toggle"() {
        for (const bad of ["", "not json", "null", "[]", '{"available": "yes"}'])
            assert.deepStrictEqual(plain(lib.parseLockStatus(bad)), {available: false, enabled: false}, bad)
        assert.deepStrictEqual(plain(lib.parseLockStatus('{"available": true, "enabled": true, "design": "x"}')), {available: true, enabled: true})
    },
    "fetcher output is parsed defensively"() {
        assert.strictEqual(lib.parseEvent("not json"), null)
        assert.strictEqual(lib.parseEvent("[1]"), null)
        assert.strictEqual(lib.parseEvent('{"event": "done"}').event, "done")
        assert.strictEqual(lib.parseLibrary("nope"), null)
        const report = lib.parseLibrary('{"clips": {"a.mov": 5, "../b.mov": 9}, "thumbnails": ["a.mov.png"], "free": 7, "catalogAge": null}')
        assert.deepStrictEqual(plain(report), {clips: {"a.mov": 5}, thumbnails: {"a.mov.png": true}, free: 7, catalogAge: null})
    },
}

let failed = 0
for (const [name, test] of Object.entries(tests)) {
    try { test(); console.log("ok   " + name) }
    catch (error) { failed++; console.log("FAIL " + name + "\n     " + error.message) }
}
console.log(`${Object.keys(tests).length - failed} passed, ${failed} failed`)
process.exit(failed ? 1 : 0)
