-- Aerial: playlist, transitions, clock, captions and dismissal.

local mp = require "mp"
local utils = require "mp.utils"
local msg = require "mp.msg"
local options = require "mp.options"

local SCREENSAVER_CLASS = "org.omarchy.screensaver"
local VIDEO_EXTENSIONS = { mov = true, mp4 = true, m4v = true, mkv = true, webm = true }

local opts = {
  -- Passed by bin/aerial.
  data = "",
  state = "",
  config = "",
  index = 0,
  count = 1,
  seed = 0,
  cli = "",
  preview = false,
  -- User settings, normally from ~/.config/aerial/aerial.conf.
  mode = "cycle", -- cycle through downloaded clips, or one to keep playing clip
  clip = "", -- the file to keep playing when mode is one
  clock = "on", -- on or off
  clock_format = "24h", -- 12h or 24h, from the system, passed by bin/aerial
  captions = true,
  categories = "", -- comma separated, empty means all
  font = "Adwaita Sans",
  fade_in = 2.0,
  fade_out = 2.0,
}

-- Overlay geometry, as a fraction of screen height.
local MARGIN = 0.05
local CLOCK_SIZE = 0.078
local CAPTION_SIZE = 0.0195

local TICK = 1 / 30
local CAPTION_FADE = 0.7 -- seconds, each way
local INPUT_GRACE = 1.5 -- ignore the motion a window gets as it maps
local FOCUS_GRACE = 3.0 -- the launcher moves focus around while starting
local MOUSE_THRESHOLD = 12 -- pixels of travel, so a bumped desk does not wake it

local function read_file(path)
  local file = io.open(path, "r")
  if not file then return nil end
  local content = file:read("*a")
  file:close()
  return content
end

local function apply_config_file(path)
  local content = path ~= "" and read_file(path)
  if not content then return end
  for line in content:gmatch("[^\r\n]+") do
    local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
    if key and opts[key] ~= nil then
      local kind = type(opts[key])
      if kind == "boolean" then
        opts[key] = value == "yes" or value == "true"
      elseif kind == "number" then
        opts[key] = tonumber(value) or opts[key]
      else
        opts[key] = value
      end
    end
  end
end

-- read_options is called twice: the first finds the config path, the second lets
-- anything on the command line win over the config file.
options.read_options(opts, "aerial")
apply_config_file(opts.config)
options.read_options(opts, "aerial")

local function load_catalog()
  local content = read_file(utils.join_path(opts.data, "catalog.json"))
  local parsed = content and utils.parse_json(content)
  return parsed and parsed.clips or {}
end

local catalog = load_catalog()

----------------------------------------------------------------------------
-- Playlist
----------------------------------------------------------------------------

local recent_path = utils.join_path(opts.state, "recent")

local function read_recent()
  local recent = {}
  for name in (read_file(recent_path) or ""):gmatch("[^\n]+") do
    table.insert(recent, name)
  end
  return recent
end

local function wanted_categories()
  local wanted, any = {}, false
  for name in opts.categories:gmatch("[^,%s]+") do
    wanted[name:lower()] = true
    any = true
  end
  return any and wanted or nil
end

local function find_clips()
  local names = utils.readdir(utils.join_path(opts.data, "videos"), "files") or {}
  local wanted = wanted_categories()
  local all, filtered = {}, {}
  table.sort(names)
  for _, name in ipairs(names) do
    local extension = name:match("%.(%w+)$")
    if extension and VIDEO_EXTENSIONS[extension:lower()] then
      table.insert(all, name)
      -- Videos the catalogue does not know are the user's own, so always keep them.
      local clip = catalog[name]
      if not wanted or not clip or wanted[(clip.category or ""):lower()] then
        table.insert(filtered, name)
      end
    end
  end
  return #filtered > 0 and filtered or all
end

-- Shuffle, then push recently seen clips to the back so that a short idle does
-- not replay what the last one showed. Monitors share a seed and each starts at
-- a different offset, so they show different clips.
local function build_playlist()
  if opts.mode == "one" and opts.clip ~= "" then
    if utils.file_info(utils.join_path(utils.join_path(opts.data, "videos"), opts.clip)) then
      return { opts.clip }
    end
    -- It may have been deleted or still be downloading, and cycling beats a blank screen.
    msg.warn("kept clip not found, cycling instead: " .. opts.clip)
  end

  local clips = find_clips()
  math.randomseed(opts.seed)
  for i = #clips, 2, -1 do
    local j = math.random(i)
    clips[i], clips[j] = clips[j], clips[i]
  end

  local recent_rank = {}
  for rank, name in ipairs(read_recent()) do recent_rank[name] = rank end
  local fresh, seen = {}, {}
  for _, name in ipairs(clips) do
    table.insert(recent_rank[name] and seen or fresh, name)
  end
  table.sort(seen, function(a, b) return recent_rank[a] < recent_rank[b] end)
  for _, name in ipairs(seen) do table.insert(fresh, name) end

  local playlist = {}
  local offset = #fresh > 0 and (opts.index * math.floor(#fresh / math.max(opts.count, 1))) % #fresh or 0
  for i = 1, #fresh do
    playlist[i] = fresh[(i - 1 + offset) % #fresh + 1]
  end
  return playlist
end

local function remember(name, total)
  local kept = {}
  for _, other in ipairs(read_recent()) do
    if other ~= name then table.insert(kept, other) end
  end
  table.insert(kept, name)
  local limit = math.floor(total * 0.7)
  while #kept > limit do table.remove(kept, 1) end
  local temporary = recent_path .. "." .. utils.getpid()
  local file = io.open(temporary, "w")
  if not file then return end
  file:write(table.concat(kept, "\n"), "\n")
  file:close()
  os.rename(temporary, recent_path)
end

----------------------------------------------------------------------------
-- Dismissal
----------------------------------------------------------------------------

local started_at = mp.get_time()
local dismissed = false

local function dismiss(reason)
  if dismissed then return end
  dismissed = true
  msg.info("dismissed: " .. reason)
  -- Every monitor has its own player, and any input ends them all. The bracket
  -- keeps this pattern from matching pkill's own command line.
  mp.command_native_async({
    name = "subprocess",
    args = { "pkill", "-f", "[o]rg.omarchy.screensaver" },
    detach = true,
    playback_only = false,
  }, function() end)
  mp.command("quit")
end

mp.add_key_binding(nil, "dismiss", function()
  if mp.get_time() - started_at > INPUT_GRACE then dismiss("input") end
end)

local pointer_origin = nil

mp.observe_property("mouse-pos", "native", function(_, position)
  if not position or not position.hover then return end
  if mp.get_time() - started_at < INPUT_GRACE or not pointer_origin then
    pointer_origin = position
    return
  end
  local travel = math.abs(position.x - pointer_origin.x) + math.abs(position.y - pointer_origin.y)
  if travel > MOUSE_THRESHOLD then dismiss("pointer") end
end)

-- Something else took focus, such as an app opened from the launcher. The
-- special workspace would otherwise sit on top of it. Losing focus to another
-- monitor's player is fine, and neither is a layer-shell menu that is still open,
-- so ask Hyprland what is active, and only while this window is unfocused.
local function check_active_window()
  if mp.get_time() - started_at < FOCUS_GRACE then return end
  mp.command_native_async({
    name = "subprocess",
    args = { "hyprctl", "activewindow", "-j" },
    capture_stdout = true,
    playback_only = false,
  }, function(success, result)
    if not success or not result or result.status ~= 0 then return end
    local window = utils.parse_json(result.stdout or "")
    if window and window.class and window.class ~= SCREENSAVER_CLASS then
      dismiss("focus moved to " .. window.class)
    end
  end)
end

local focus_timer = mp.add_periodic_timer(1, check_active_window)
focus_timer:stop()

mp.observe_property("focused", "bool", function(_, focused)
  if focused == false then focus_timer:resume() else focus_timer:stop() end
end)

----------------------------------------------------------------------------
-- Overlay
----------------------------------------------------------------------------

local overlay = mp.create_osd_overlay("ass-events")
local needs_render = true
local video_fade = 0
local clock_text = ""
local clock_fade = 0
local caption_text = ""
local caption_target = ""
local caption_fade = 0
local points_of_interest = {}

local function ass_escape(text)
  return (text:gsub("\\", "\\\239\187\191"):gsub("{", "\\{"):gsub("\n", " "))
end

local function ass_alpha(opacity)
  return string.format("&H%02X&", math.floor((1 - math.max(0, math.min(1, opacity))) * 255 + 0.5))
end

-- White text over a soft dark halo, which keeps it legible on bright footage
-- without the hard outline subtitles usually have.
local function text_events(x, y, size, text, opacity, weight, spacing)
  if text == "" or opacity <= 0 then return {} end
  local base = string.format("{\\an1\\pos(%d,%d)\\q2\\fn%s\\fs%d\\b%d\\fsp%g\\shad0",
    x, y, opts.font, size, weight, spacing)
  local halo = ass_alpha(opacity * 0.6)
  return {
    string.format("%s\\bord%d\\blur%d\\1c&H000000&\\3c&H000000&\\1a%s\\3a%s}%s",
      base, math.max(1, math.floor(size * 0.03)), math.max(2, math.floor(size * 0.14)), halo, halo, text),
    string.format("%s\\bord0\\1c&HFFFFFF&\\1a%s}%s", base, ass_alpha(opacity), text),
  }
end

local function render()
  local width, height = mp.get_osd_size()
  if not width or width == 0 or height == 0 then return end
  overlay.res_x, overlay.res_y = width, height

  local margin = math.floor(height * MARGIN)
  local clock_size = math.floor(height * CLOCK_SIZE)
  local caption_size = math.floor(height * CAPTION_SIZE)
  local caption_y = height - margin
  local clock_y = caption_y - math.floor(caption_size * 1.55)

  local events = {}
  for _, event in ipairs(text_events(margin, clock_y, clock_size, clock_text, clock_fade * 0.95, 300, -clock_size * 0.012)) do
    table.insert(events, event)
  end
  local caption_opacity = caption_fade * video_fade * 0.9
  for _, event in ipairs(text_events(margin + math.floor(clock_size * 0.04), caption_y, caption_size,
    ass_escape(caption_text), caption_opacity, 400, caption_size * 0.01)) do
    table.insert(events, event)
  end
  overlay.data = table.concat(events, "\n")
  overlay:update()
end

local function current_clock()
  if opts.clock == "off" then return "" end
  if opts.clock_format == "24h" then return os.date("%H:%M") end
  return (os.date("%I:%M"):gsub("^0", ""))
end

local function smoothstep(value)
  value = math.max(0, math.min(1, value))
  return value * value * (3 - 2 * value)
end

local last_contrast = -100

local function set_fade(level)
  local contrast = math.floor(level * 100 + 0.5) - 100
  if contrast == last_contrast then return end
  last_contrast = contrast
  mp.set_property_number("contrast", contrast)
end

local function update_transition()
  local position = mp.get_property_number("time-pos")
  local duration = mp.get_property_number("duration")
  local level = 0
  if position and duration and duration > 0 then
    -- The small offsets hold pure black across the switch between clips, which
    -- hides the moment mpv spends opening the next one.
    local into = (position - 0.15) / opts.fade_in
    local out = (duration - position - 0.3) / opts.fade_out
    level = smoothstep(math.min(into, out))
  end
  set_fade(level)
  if math.abs(level - video_fade) > 0.001 then
    video_fade = level
    needs_render = true
  end
  return position
end

local function update_clock(delta)
  local text = current_clock()
  if text ~= clock_text then
    clock_text = text
    mp.set_property_native("user-data/aerial/clock", text)
    needs_render = true
  end
  -- The clock fades in once, with the first clip, and stays through transitions.
  if clock_fade < 1 and video_fade > 0 then
    clock_fade = math.min(1, clock_fade + delta / opts.fade_in)
    needs_render = true
  end
end

local function update_caption(position, delta)
  local target = ""
  if opts.captions and position then
    for _, point in ipairs(points_of_interest) do
      if point.time <= position then target = point.text else break end
    end
  end
  caption_target = target

  if caption_text ~= caption_target then
    -- Fade the old caption out completely before bringing in the new one.
    if caption_fade > 0 then
      caption_fade = math.max(0, caption_fade - delta / CAPTION_FADE)
    else
      caption_text = caption_target
    end
    needs_render = true
  elseif caption_text ~= "" and caption_fade < 1 then
    caption_fade = math.min(1, caption_fade + delta / CAPTION_FADE)
    needs_render = true
  end
end

local last_tick = mp.get_time()

mp.add_periodic_timer(TICK, function()
  local now = mp.get_time()
  local delta = now - last_tick
  last_tick = now
  local position = update_transition()
  update_clock(delta)
  update_caption(position, delta)
  if needs_render then
    needs_render = false
    render()
  end
end)

mp.observe_property("osd-dimensions", "native", function() needs_render = true end)

----------------------------------------------------------------------------
-- Clip lifecycle
----------------------------------------------------------------------------

local playlist = build_playlist()
local failures = 0

mp.register_event("start-file", function()
  set_fade(0)
  video_fade = 0
end)

mp.register_event("file-loaded", function()
  failures = 0
  local name = mp.get_property("filename") or ""
  local clip = catalog[name]
  points_of_interest = {}
  if clip then
    for time, text in pairs(clip.pois or {}) do
      table.insert(points_of_interest, { time = tonumber(time) or 0, text = text })
    end
    table.sort(points_of_interest, function(a, b) return a.time < b.time end)
    if #points_of_interest == 0 and clip.label then
      points_of_interest = { { time = 0, text = clip.label } }
    end
  end
  caption_fade, caption_text = 0, ""
  needs_render = true
  -- A kept clip or a preview says nothing about what the rotation has shown.
  if opts.mode ~= "one" then remember(name, #playlist) end
  -- The lock screen shows what was last playing, if clips play there at all.
  if opts.cli ~= "" and not opts.preview then
    mp.command_native_async({
      name = "subprocess",
      args = { opts.cli, "lock", "follow", name },
      detach = true,
      playback_only = false,
    }, function() end)
  end
end)

mp.register_event("end-file", function(event)
  if event.reason ~= "error" then return end
  failures = failures + 1
  msg.warn("could not play clip: " .. tostring(event.file_error))
  if failures >= #playlist then dismiss("no clip could be played") end
end)

if #playlist == 0 then
  dismiss("no clips found")
else
  local directory = utils.join_path(opts.data, "videos")
  for _, name in ipairs(playlist) do
    mp.commandv("loadfile", utils.join_path(directory, name), "append-play")
  end
end
