local wezterm = require("wezterm")

local M = {}

local window_state = {}
local runtime = nil
local handlers_registered = false

local default_colors = {
  cursor_bg = "#78fbff",
  cursor_border = "#78fbff",
  cursor_fg = "#02060b",
  selection_bg = "#172a38",
  selection_fg = "#e7fbff",
  split = "#1b5268",
  visual_bell = "#b48cff",
}

local default_visual_bell = {
  fade_in_duration_ms = 75,
  fade_out_duration_ms = 125,
  fade_in_function = "EaseIn",
  fade_out_function = "EaseOut",
  target = "CursorColor",
}

local default_shell_processes = {
  bash = true,
  fish = true,
  nu = true,
  sh = true,
  tmux = true,
  zsh = true,
}

local function opt(options, key, default)
  if options[key] == nil then
    return default
  end

  return options[key]
end

local function dirname(path)
  return path:match("^(.*)[/\\][^/\\]+$") or "."
end

local function plugin_root()
  local source = debug.getinfo(1, "S").source
  if source:sub(1, 1) ~= "@" then
    error("electric-control-room.wez: unable to resolve plugin directory")
  end

  return dirname(dirname(source:sub(2)))
end

local function path_join(...)
  return table.concat({ ... }, package.config:sub(1, 1))
end

local function basename(path)
  return (path or ""):gsub("\\", "/"):match("([^/]+)$") or ""
end

local function merge_colors(config, colors)
  local target = config.colors or {}
  for key, value in pairs(colors) do
    target[key] = value
  end
  config.colors = target
end

local function copy_shell_processes(processes)
  local copy = {}
  for key, value in pairs(processes or default_shell_processes) do
    copy[key] = value
  end
  return copy
end

local function build_backgrounds(options)
  local assets_dir = opt(options, "assets_dir", path_join(plugin_root(), "assets"))

  local base_gradient = {
    source = {
      Gradient = {
        orientation = { Linear = { angle = -22.0 } },
        colors = { "#01030a", "#021116", "#02040c" },
        interpolation = "Linear",
        blend = "Rgb",
      },
    },
    width = "100%",
    height = "100%",
    opacity = 1.0,
  }

  local shade_gradient = {
    source = {
      Gradient = {
        orientation = "Vertical",
        colors = { "#000104", "#000b10", "#000104" },
        interpolation = "Linear",
        blend = "Rgb",
      },
    },
    width = "100%",
    height = "100%",
    opacity = 0.72,
  }

  local dormant_background = {
    base_gradient,
    shade_gradient,
    {
      source = {
        File = {
          path = path_join(assets_dir, "control-room-dormant.png"),
          speed = opt(options, "dormant_speed", 1.0),
        },
      },
      width = "Cover",
      height = "Cover",
      horizontal_align = "Center",
      vertical_align = "Middle",
      repeat_x = "NoRepeat",
      repeat_y = "NoRepeat",
      opacity = opt(options, "dormant_opacity", 0.14),
      attachment = "Fixed",
    },
  }

  local active_background = {
    base_gradient,
    shade_gradient,
    {
      source = {
        File = {
          path = path_join(assets_dir, "control-room-sweep.png"),
          speed = opt(options, "sweep_speed", 1.0),
        },
      },
      width = "Cover",
      height = "Cover",
      horizontal_align = "Center",
      vertical_align = "Middle",
      repeat_x = "NoRepeat",
      repeat_y = "NoRepeat",
      opacity = opt(options, "sweep_opacity", 0.24),
      attachment = "Fixed",
    },
  }

  return active_background, dormant_background
end

local function pane_signature(pane)
  local process = basename(pane:get_foreground_process_name())
  return process .. "\n" .. (pane:get_lines_as_text(10) or ""), process
end

local function set_window_paused(window, paused)
  if not runtime then
    return
  end

  local id = window:window_id()
  local state = window_state[id] or {}
  window_state[id] = state

  if state.paused == paused then
    return
  end

  state.paused = paused
  local overrides = window:get_config_overrides() or {}
  if paused then
    overrides.background = runtime.dormant_background
  else
    overrides.background = nil
  end
  window:set_config_overrides(overrides)
end

local function window_should_animate(window, pane)
  if not runtime or not runtime.pause_when_idle then
    return true
  end

  if window:is_focused() then
    return true
  end

  local id = window:window_id()
  local state = window_state[id] or { quiet_ticks = 0 }
  window_state[id] = state

  local signature, process = pane_signature(pane)
  local changed = signature ~= state.signature
  state.signature = signature

  if changed then
    state.quiet_ticks = 0
  else
    state.quiet_ticks = (state.quiet_ticks or 0) + 1
  end

  if process ~= "" and not runtime.shell_processes[process] then
    return true
  end

  return state.quiet_ticks < 3
end

local function register_handlers()
  if handlers_registered then
    return
  end

  handlers_registered = true

  wezterm.on("update-status", function(window, pane)
    set_window_paused(window, not window_should_animate(window, pane))
  end)

  wezterm.on("window-focus-changed", function(window, pane)
    set_window_paused(window, not window_should_animate(window, pane))
  end)
end

function M.apply_to_config(config, options)
  options = options or {}

  local active_background, dormant_background = build_backgrounds(options)
  runtime = {
    active_background = active_background,
    dormant_background = dormant_background,
    pause_when_idle = opt(options, "pause_when_idle", true),
    shell_processes = copy_shell_processes(options.shell_processes),
  }

  if opt(options, "set_color_scheme", true) then
    config.color_scheme = opt(options, "color_scheme", "Catppuccin Mocha")
  end

  if opt(options, "set_colors", true) then
    merge_colors(config, opt(options, "colors", default_colors))
  end

  config.background = active_background
  config.window_background_opacity = opt(options, "window_background_opacity", 0.96)
  config.macos_window_background_blur = opt(options, "macos_window_background_blur", 20)
  config.animation_fps = opt(options, "animation_fps", 24)
  config.max_fps = opt(options, "max_fps", 60)
  config.default_cursor_style = opt(options, "cursor_style", "BlinkingBar")
  config.cursor_blink_rate = opt(options, "cursor_blink_rate", 650)
  config.cursor_blink_ease_in = opt(options, "cursor_blink_ease_in", "EaseIn")
  config.cursor_blink_ease_out = opt(options, "cursor_blink_ease_out", "EaseOut")
  config.visual_bell = opt(options, "visual_bell", default_visual_bell)

  if runtime.pause_when_idle then
    config.status_update_interval = opt(
      options,
      "status_update_interval",
      config.status_update_interval or 2000
    )
    register_handlers()
  end
end

return M
