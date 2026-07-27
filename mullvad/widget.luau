--!nonstrict
-- Mullvad VPN bar widget.
--
-- Shows the VPN state and opens the panel or toggles the connection on click.

local currentStatus = noctalia.state.get("mullvad.status") or {}

local function flagEmoji(code)
  local c = (code or ""):upper()
  if #c ~= 2 then
    return ""
  end
  return utf8.char(0x1F1E6 + c:byte(1) - 65, 0x1F1E6 + c:byte(2) - 65)
end

local function stateColor(vpnState, installed, locked)
  if not installed then
    return "error"
  end
  if vpnState == "connected" then
    return "primary"
  end
  if vpnState == "connecting" or vpnState == "disconnecting" then
    return "tertiary"
  end
  if locked or vpnState == "error" then
    return "error"
  end
  return "on_surface"
end

local function render()
  local installed = currentStatus.installed == true
  local vpnState = currentStatus.state or "disconnected"
  local locked = currentStatus.locked == true
  local location = currentStatus.location

  local compact = noctalia.getConfig("compact_mode") == true
  local showFlag = noctalia.getConfig("show_country_flag") == true
  local showCity = noctalia.getConfig("show_city_name") == true
  local showIp = noctalia.getConfig("show_ip") == true

  local glyph = installed and "shield" or "shield-off"
  barWidget.setGlyph(glyph)
  barWidget.setGlyphColor(stateColor(vpnState, installed, locked))

  local isVertical = barWidget.isVertical()
  if compact or isVertical then
    barWidget.setText("")
  else
    local parts = {}
    if showFlag and vpnState == "connected" and location and location.country ~= "" then
      table.insert(parts, flagEmoji(location.country))
    end
    if showCity and vpnState == "connected" and location and location.city ~= "" then
      table.insert(parts, location.city)
    end
    if showIp and vpnState == "connected" and location and location.ipv4 ~= "" then
      table.insert(parts, location.ipv4)
    end
    barWidget.setText(table.concat(parts, " "))
  end

  local tooltip
  if not installed then
    tooltip = noctalia.tr("state.not_installed")
  elseif vpnState == "error" then
    tooltip = noctalia.tr("state.error")
  elseif vpnState == "connected" and location then
    tooltip = noctalia.tr("state.connected") .. ": " .. (location.city or location.country or "")
    if location.hostname ~= "" then
      tooltip = tooltip .. "\n" .. location.hostname
    end
    if location.ipv4 ~= "" then
      tooltip = tooltip .. "\n" .. location.ipv4
    end
  elseif locked then
    tooltip = noctalia.tr("state.blocked")
  else
    tooltip = noctalia.tr("state.disconnected")
  end
  barWidget.setTooltip(tooltip)
end

function update()
  render()
end

function onClick()
  local action = noctalia.getConfig("click_action")
  if action == "panel" then
    noctalia.togglePanel("noctalia/mullvad:panel")
  else
    noctalia.state.set("mullvad.command", { action = "toggle" })
  end
end

function onRightClick()
  noctalia.togglePanel("noctalia/mullvad:panel")
end

function onIpc(event, payload)
  if event == "toggle" then
    noctalia.state.set("mullvad.command", { action = "toggle" })
  elseif event == "connect" then
    noctalia.state.set("mullvad.command", { action = "connect" })
  elseif event == "disconnect" then
    noctalia.state.set("mullvad.command", { action = "disconnect" })
  elseif event == "reconnect" then
    noctalia.state.set("mullvad.command", { action = "reconnect" })
  elseif event == "refresh" then
    noctalia.state.set("mullvad.command", { action = "refresh" })
  elseif event == "setLocation" then
    local parts = {}
    for part in (payload or ""):gmatch("%S+") do
      table.insert(parts, part)
    end
    noctalia.state.set("mullvad.command", {
      action = "setLocation",
      country = parts[1] or "",
      city = parts[2] or "",
      hostname = parts[3] or "",
    })
  elseif event == "setLockdown" then
    noctalia.state.set("mullvad.command", { action = "setLockdown", on = payload == "true" or payload == "on" })
  end
end

noctalia.state.watch("mullvad.status", function(value)
  currentStatus = value
  render()
end)

render()
