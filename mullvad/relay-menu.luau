--!nonstrict
-- Relay selection menu for a single country.

local currentStatus = noctalia.state.get("mullvad.status") or {}
local menuTarget = noctalia.state.get("mullvad.menuTarget") or {}

local function flagEmoji(code)
  local c = (code or ""):upper()
  if #c ~= 2 then
    return ""
  end
  return utf8.char(0x1F1E6 + c:byte(1) - 65, 0x1F1E6 + c:byte(2) - 65)
end

local function findCountry(code)
  for _, c in ipairs(currentStatus.relayList or {}) do
    if c.code == code then
      return c
    end
  end
  return nil
end

local function connect(countryCode, cityCode, hostname)
  noctalia.state.set("mullvad.command", {
    action = "setLocation",
    country = countryCode,
    city = cityCode,
    hostname = hostname,
    connect = noctalia.getConfig("relay_click_connects") ~= false,
  })
  panel.close()
end

local function serverRow(label, countryCode, cityCode, hostname)
  return ui.row({
    gap = 8,
    align = "center",
    padding = 8,
    onClick = function()
      connect(countryCode, cityCode, hostname)
    end,
  }, {
    ui.label({ text = label, color = "on_surface", flexGrow = 1 }),
  })
end

function render()
  local target = menuTarget
  local code = target.countryCode or ""
  local country = findCountry(code)
  local title = target.countryName or code:upper()
  local rows = {}

  table.insert(rows, ui.row({
    gap = 8,
    align = "center",
    justify = "space_between",
  }, {
    ui.label({
      text = flagEmoji(code) .. " " .. noctalia.tr("relay.menu_title", { country = title }),
      fontWeight = "bold",
      color = "on_surface",
      flexGrow = 1,
    }),
    ui.button({
      glyph = "x",
      variant = "ghost",
      onClick = "onClose",
    }),
  }))
  table.insert(rows, ui.separator())

  if country then
    table.insert(rows, serverRow(noctalia.tr("relay.menu_any"), code, "", ""))
    for _, city in ipairs(country.cities) do
      table.insert(rows, ui.label({
        text = city.city,
        fontWeight = "medium",
        color = "on_surface_variant",
      }))
      for _, host in ipairs(city.hostnames) do
        table.insert(rows, serverRow("  " .. host.name .. "  " .. host.ipv4, code, city.code, host.name))
      end
    end
  end

  if #rows == 2 then
    table.insert(rows, ui.row({ padding = 12 }, {
      ui.label({ text = noctalia.tr("relay.no_results"), color = "on_surface_variant" }),
    }))
  end

  panel.render(ui.column({ gap = 4, align = "stretch" }, {
    ui.scroll({ flexGrow = 1, align = "stretch" }, rows),
  }))
end

function onOpen(_context)
  currentStatus = noctalia.state.get("mullvad.status") or {}
  menuTarget = noctalia.state.get("mullvad.menuTarget") or {}
  render()
end

function onClose()
  panel.close()
end

noctalia.state.watch("mullvad.status", function(value)
  currentStatus = value
  render()
end)

render()
