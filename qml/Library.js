// The app's rules, free of QML so tests/test_library.cjs can run them directly.

const MaxClips = 1000
const MaxLabel = 120

// Catalogue keys become file names, so accept only what the fetcher produces.
function validName(name) {
    return /^[a-z0-9][a-z0-9-]*\.mov$/.test(String(name))
}

function parseCatalog(text) {
    let clips
    try { clips = JSON.parse(text).clips } catch (error) { return [] }
    if (!clips || typeof clips !== "object") return []
    return Object.keys(clips).filter(validName).slice(0, MaxClips).map(name => {
        const entry = clips[name] || {}
        return {
            name: name,
            label: String(entry.label || name).slice(0, MaxLabel),
            category: String(entry.category || ""),
            bytes: Number(entry.size) || 0
        }
    }).sort((a, b) => a.label.localeCompare(b.label))
}

// Keeps the object for any clip that did not change, so a refresh leaves the
// grid's cards and scroll position alone.
function reuseClips(previous, next) {
    const known = {}
    for (const clip of previous) known[clip.name] = clip
    return next.map(clip => {
        const old = known[clip.name]
        return old && old.label === clip.label && old.category === clip.category && old.bytes === clip.bytes ? old : clip
    })
}

function visibleClips(clips, filter, onDisk) {
    if (filter === "all") return clips
    if (filter === "downloaded") return clips.filter(clip => onDisk[clip.name] !== undefined)
    return clips.filter(clip => clip.category === filter)
}

function cycleCount(clips, category, onDisk) {
    return clips.filter(clip => onDisk[clip.name] !== undefined && (!category || clip.category === category)).length
}

function usedBytes(onDisk) {
    return Object.keys(onDisk).reduce((total, name) => total + (Number(onDisk[name]) || 0), 0)
}

// aerial.conf holds key=value lines that mpv/scripts/aerial.lua also reads, so
// this has to accept the same shape.
const SettingLine = /^\s*([A-Za-z0-9_]+)\s*=\s*(.*?)\s*$/

function parseConfig(text) {
    const values = {}
    for (const line of String(text).split("\n")) {
        const match = SettingLine.exec(line)
        if (match) values[match[1]] = match[2]
    }
    return values
}

// People edit the file by hand too, so only the given values change, and
// comments and everything else stay where they are.
function mergeConfig(text, values) {
    const lines = String(text) === "" ? [] : String(text).split("\n")
    if (lines.length && lines[lines.length - 1] === "") lines.pop()
    const written = {}
    const merged = lines.map(line => {
        const match = SettingLine.exec(line)
        if (!match || !(match[1] in values)) return line
        written[match[1]] = true
        return match[1] + "=" + values[match[1]]
    })
    for (const key of Object.keys(values).sort())
        if (!written[key]) merged.push(key + "=" + values[key])
    return merged.join("\n") + "\n"
}

function settingsFrom(values) {
    const categories = values.categories || ""
    return {
        mode: values.mode === "one" ? "one" : "cycle",
        clip: validName(values.clip) ? values.clip : "",
        // One category can be picked here. A hand-written list stays in the
        // file until something else is chosen, and shows as everything meanwhile.
        cycleCategory: categories.indexOf(",") >= 0 ? "" : categories,
        clockOn: values.clock !== "off",
        captions: values.captions === undefined || values.captions === "yes" || values.captions === "true"
    }
}

// A locale's time format with no AM/PM marker is a 24-hour clock. The same test
// Omarchy's Elsewhen panel uses, with quoted literals set aside first.
function usesTwentyFourHour(timeFormat) {
    return !/[Aa]/.test(String(timeFormat === undefined || timeFormat === null ? "" : timeFormat).replace(/'[^']*'/g, ""))
}

// What "Keep one" should keep when no clip was named: the selected one, the
// last one kept, then the first on disk. Empty when nothing is here to keep.
function clipToKeep(selected, kept, clips, onDisk) {
    if (selected && onDisk[selected] !== undefined) return selected
    if (kept && onDisk[kept] !== undefined) return kept
    const first = clips.find(clip => onDisk[clip.name] !== undefined)
    return first ? first.name : ""
}

// The sharp frame cut from a clip on disk, else Apple's smaller preview.
function thumbnailPath(name, downloaded, thumbnails, directory) {
    if (downloaded && thumbnails[name + ".jpg"]) return directory + "/" + name + ".jpg"
    if (thumbnails[name + ".png"]) return directory + "/" + name + ".png"
    return ""
}

function parseEvent(line) {
    try {
        const event = JSON.parse(line)
        return event && typeof event === "object" && typeof event.event === "string" ? event : null
    } catch (error) { return null }
}

function parseLibrary(text) {
    let report
    try { report = JSON.parse(text) } catch (error) { return null }
    if (!report || typeof report !== "object") return null
    const clips = {}
    for (const name of Object.keys(report.clips || {}))
        if (validName(name)) clips[name] = Number(report.clips[name]) || 0
    const thumbnails = {}
    for (const name of report.thumbnails || []) thumbnails[name] = true
    const age = report.catalogAge
    return { clips: clips, thumbnails: thumbnails, free: Number(report.free) || 0, catalogAge: typeof age === "number" ? age : null }
}

// What bin/aerial says about the lock screen. Anything unreadable means no toggle.
function parseLockStatus(text) {
    let status
    try { status = JSON.parse(text) } catch (error) { return {available: false, enabled: false} }
    return {available: !!status && status.available === true, enabled: !!status && status.enabled === true}
}
