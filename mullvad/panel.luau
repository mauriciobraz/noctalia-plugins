--!nonstrict
-- Mullvad VPN panel.

local currentStatus = noctalia.state.get("mullvad.status") or {}

local searchQuery = ""
local searchKey = 0
local advancedExpanded = false
local confirmDisconnect = false
local expandedCountries = {}
local expandedCities = {}

local dnsInput = ""
local dnsCustomDraft = false
local acPortInputs = {
  udp2tcp = "",
  shadowsocks = "",
  ["wireguard-port"] = "",
  lwo = "",
}

-- ── Helpers ──

local function flagEmoji(code)
  local c = (code or ""):upper()
  if #c ~= 2 then
    return ""
  end
  return utf8.char(0x1F1E6 + c:byte(1) - 65, 0x1F1E6 + c:byte(2) - 65)
end

local function countryName(code)
  if not code or code == "" then
    return ""
  end
  for _, c in ipairs(currentStatus.relayList or {}) do
    if c.code == code then
      return c.country
    end
  end
  return code:upper()
end

local function statusColor()
  if not currentStatus.installed then
    return "error"
  end
  local state = currentStatus.state or "disconnected"
  if state == "connected" then
    return "primary"
  end
  if state == "connecting" or state == "disconnecting" then
    return "tertiary"
  end
  if currentStatus.locked or state == "error" then
    return "error"
  end
  return "on_surface"
end

local function groupBox(children)
  return ui.box({ fill = "surface_variant/0.4", radius = 8, padding = 12 }, {
    ui.column({ gap = 12, align = "stretch" }, children),
  })
end

local function toggleRow(labelKey, checked, callback)
  return ui.row({ gap = 12, align = "center", justify = "space_between" }, {
    ui.label({ text = noctalia.tr(labelKey), color = "on_surface" }),
    ui.toggle({ checked = checked == true, onChange = callback }),
  })
end

-- ── Relay list ──

local function activateRow(countryCode, cityCode, hostname)
  noctalia.state.set("mullvad.command", {
    action = "setLocation",
    country = countryCode or "",
    city = cityCode or "",
    hostname = hostname or "",
    connect = noctalia.getConfig("relay_click_connects") ~= false,
  })
end

local function toggleExpandRow(kind, countryCode, cityCode)
  if kind == "country" then
    if expandedCountries[countryCode] then
      expandedCountries[countryCode] = nil
    else
      expandedCountries[countryCode] = true
    end
  elseif kind == "city" then
    local key = countryCode .. ":" .. cityCode
    if expandedCities[key] then
      expandedCities[key] = nil
    else
      expandedCities[key] = true
    end
  end
  render()
end

local function matches(query, country, city, host)
  if query == "" then
    return true
  end
  local hay = country.country .. " " .. country.code
  if city then
    hay = hay .. " " .. city.city .. " " .. city.code
  end
  if host then
    hay = hay .. " " .. host.name .. " " .. host.ipv4
  end
  return string.find(hay:lower(), query, 1, true) ~= nil
end

local function buildRelayRows()
  local query = noctalia.string.trim(searchQuery):lower()
  local rl = currentStatus.relayList or {}
  local fav = currentStatus.favoriteCountries or {}
  local sel = currentStatus.relaySelection or { country = "", city = "", hostname = "" }

  local ordered = {}
  for _, c in ipairs(rl) do
    table.insert(ordered, c)
  end
  table.sort(ordered, function(a, b)
    local af = table.find(fav, a.code) ~= nil
    local bf = table.find(fav, b.code) ~= nil
    if af ~= bf then
      return af
    end
    return a.country < b.country
  end)

  local rows = {}
  for _, country in ipairs(ordered) do
    local countryExpanded = expandedCountries[country.code] == true
    local hasMatch = matches(query, country, nil, nil)
    local cityMatched = false
    local hostMatched = false
    for _, city in ipairs(country.cities) do
      if matches(query, country, city, nil) then
        cityMatched = true
      end
      for _, host in ipairs(city.hostnames) do
        if matches(query, country, city, host) then
          hostMatched = true
        end
      end
    end
    if not hasMatch and not cityMatched and not hostMatched and not countryExpanded then
      continue
    end

    local totalHosts = 0
    for _, city in ipairs(country.cities) do
      totalHosts += #city.hostnames
    end

    local isCurrent = sel.country == country.code and sel.city == ""
    local expandGlyph = countryExpanded and "chevron-up" or "chevron-down"

    table.insert(rows, ui.row({
      gap = 8,
      align = "center",
      padding = 8,
      fill = isCurrent and "primary" or nil,
      onClick = function()
        activateRow(country.code, "", "")
      end,
      onRightClick = function()
        toggleExpandRow("country", country.code)
      end,
    }, {
      ui.label({
        text = flagEmoji(country.code) .. " " .. country.country,
        color = isCurrent and "on_primary" or "on_surface",
        flexGrow = 1,
      }),
      if totalHosts > 0
        then ui.label({
          text = tostring(totalHosts),
          color = isCurrent and "on_primary" or "on_surface_variant",
        })
        else ui.box({ width = 0 }),
      ui.button({
        glyph = expandGlyph,
        variant = "ghost",
        tooltip = noctalia.tr("relay.expand_tooltip"),
        onClick = function()
          toggleExpandRow("country", country.code)
        end,
      }),
    }))

    if not countryExpanded and query == "" then
      continue
    end

    for _, city in ipairs(country.cities) do
      local cityKey = country.code .. ":" .. city.code
      local cityExpanded = expandedCities[cityKey] == true
      local cityHostMatched = false
      for _, host in ipairs(city.hostnames) do
        if matches(query, country, city, host) then
          cityHostMatched = true
        end
      end
      if not matches(query, country, city, nil) and not cityHostMatched and not cityExpanded then
        continue
      end

      local cityCurrent = sel.country == country.code and sel.city == city.code and sel.hostname == ""
      local cityExpandGlyph = cityExpanded and "chevron-up" or "chevron-down"

      table.insert(rows, ui.row({
        gap = 8,
        align = "center",
        padding = 8,
        fill = cityCurrent and "primary" or nil,
        onClick = function()
          activateRow(country.code, city.code, "")
        end,
        onRightClick = function()
          toggleExpandRow("city", country.code, city.code)
        end,
      }, {
        ui.label({
          text = "  " .. flagEmoji(country.code) .. " " .. city.city,
          color = cityCurrent and "on_primary" or "on_surface",
          flexGrow = 1,
        }),
        if #city.hostnames > 0
          then ui.label({
            text = tostring(#city.hostnames),
            color = cityCurrent and "on_primary" or "on_surface_variant",
          })
          else ui.box({ width = 0 }),
        if #city.hostnames > 0
          then ui.button({
            glyph = cityExpandGlyph,
            variant = "ghost",
            tooltip = noctalia.tr("relay.expand_tooltip"),
            onClick = function()
              toggleExpandRow("city", country.code, city.code)
            end,
          })
          else ui.box({ width = 0 }),
      }))

      if not cityExpanded and query == "" then
        continue
      end

      for _, host in ipairs(city.hostnames) do
        if query ~= "" and not matches(query, country, city, host) then
          continue
        end
        local hostCurrent = sel.hostname == host.name
        table.insert(rows, ui.row({
          gap = 8,
          align = "center",
          padding = 8,
          fill = hostCurrent and "primary" or nil,
          onClick = function()
            activateRow(country.code, city.code, host.name)
          end,
        }, {
          ui.label({
            text = "    " .. host.name .. "  " .. host.ipv4,
            color = hostCurrent and "on_primary" or "on_surface",
            flexGrow = 1,
          }),
        }))
      end
    end
  end

  if #rows == 0 then
    table.insert(rows, ui.row({ padding = 8 }, {
      ui.label({
        text = currentStatus.relayListReady and noctalia.tr("relay.no_results") or noctalia.tr("relay.loading"),
        color = "on_surface_variant",
      }),
    }))
  end

  return rows
end

-- ── Sections ──

local function headerSection()
  local installed = currentStatus.installed == true
  local state = currentStatus.state or "disconnected"
  local location = currentStatus.location
  local selection = currentStatus.relaySelection or { country = "", city = "", hostname = "" }

  local stateText
  if not installed then
    stateText = noctalia.tr("state.not_installed")
  elseif state == "error" then
    stateText = noctalia.tr("state.error")
  elseif currentStatus.locked and state ~= "connected" then
    stateText = noctalia.tr("state.blocked")
  else
    stateText = noctalia.tr("state." .. state)
  end

  local details = {}
  if state == "connected" and location then
    local s = (location.city ~= "" and location.city) or countryName(location.country)
    if location.hostname ~= "" then
      s = s .. " / " .. location.hostname
    end
    table.insert(details, s)
  elseif selection.country ~= "" then
    local s = countryName(selection.country)
    if selection.city ~= "" then
      s = s .. " / " .. selection.city
    end
    if selection.hostname ~= "" then
      s = s .. " / " .. selection.hostname
    end
    table.insert(details, s)
  else
    table.insert(details, noctalia.tr("action.auto_select"))
  end

  if currentStatus.multihop then
    local entry = currentStatus.multihopEntry or ""
    if entry ~= "" then
      table.insert(details, noctalia.tr("badges.multihop_via", { country = countryName(entry) }))
    else
      table.insert(details, noctalia.tr("badges.multihop"))
    end
  end
  if currentStatus.ipVersion and currentStatus.ipVersion ~= "any" then
    table.insert(details, noctalia.tr("badges.ip_version", { version = currentStatus.ipVersion }))
  end
  if currentStatus.lockdownMode then
    table.insert(details, noctalia.tr("badges.lockdown"))
  end
  if currentStatus.autoConnect then
    table.insert(details, noctalia.tr("badges.auto_connect"))
  end
  if currentStatus.lanSharing == "block" then
    table.insert(details, noctalia.tr("badges.lan_blocked"))
  end

  local ipText = ""
  if location and location.ipv4 ~= "" then
    ipText = location.ipv4
  end

  local buttonText
  if state == "connected" then
    buttonText = noctalia.tr("action.disconnect")
  elseif state == "connecting" then
    buttonText = noctalia.tr("action.cancel")
  else
    buttonText = noctalia.tr("action.connect")
  end

  local children = {
    ui.row({ gap = 12, align = "center" }, {
      ui.glyph({ name = installed and "shield" or "shield-off", color = statusColor(), fontSize = 32 }),
      ui.column({ gap = 4, flexGrow = 1, align = "stretch" }, {
        ui.label({ text = stateText, fontSize = 16, fontWeight = "bold", color = "on_surface" }),
        ui.label({ text = table.concat(details, " · "), color = "on_surface_variant" }),
        if ipText ~= ""
          then ui.row({ onClick = "onCopyIp" }, {
            ui.label({ text = ipText, color = "on_surface_variant" }),
          })
          else ui.box({ width = 0, height = 0 }),
      }),
    }),
  }

  if confirmDisconnect then
    table.insert(children, ui.column({ gap = 8, align = "stretch" }, {
      ui.label({ text = noctalia.tr("confirm.lockdown_disconnect"), color = "error" }),
      ui.row({ gap = 8 }, {
        ui.button({
          text = noctalia.tr("confirm.confirm"),
          variant = "destructive",
          onClick = "onConfirmDisconnect",
        }),
        ui.button({
          text = noctalia.tr("confirm.cancel"),
          variant = "ghost",
          onClick = "onCancelDisconnect",
        }),
      }),
    }))
  else
    table.insert(children, ui.button({
      text = buttonText,
      variant = (state == "connected" or state == "connecting") and "destructive" or "primary",
      enabled = installed,
      onClick = (state == "connected" or state == "connecting") and "onDisconnectClick" or "onConnectClick",
    }))
  end

  local days = currentStatus.accountDaysLeft or 9999
  local threshold = noctalia.getConfig("expiry_warning_days")
  if type(threshold) ~= "number" then
    threshold = 7
  end
  if installed and days <= threshold then
    local text = if days <= 0
      then noctalia.tr("account.expired")
      else noctalia.tr("account.expires_in", { days = days })
    table.insert(children, ui.box({ fill = "error", radius = 8, padding = 10 }, {
      ui.label({ text = text, color = "on_error", wrap = true }),
    }))
  end

  return groupBox(children)
end

local function togglesSection()
  return groupBox({
    toggleRow("toggles.lockdown", currentStatus.lockdownMode, "onLockdown"),
    toggleRow("toggles.auto_connect", currentStatus.autoConnect, "onAutoConnect"),
    toggleRow("toggles.lan", currentStatus.lanSharing == "allow", "onLan"),
  })
end

local function relaySection()
  return groupBox({
    ui.row({ gap = 8, align = "center" }, {
      ui.input({
        key = "relay_search_" .. tostring(searchKey),
        value = searchQuery,
        placeholder = noctalia.tr("relay.search_placeholder"),
        onChange = "onSearchChange",
        flexGrow = 1,
      }),
      ui.button({
        glyph = "refresh",
        variant = "outline",
        tooltip = noctalia.tr("action.refresh_relays"),
        onClick = "onRefreshRelays",
      }),
    }),
    ui.button({
      text = noctalia.tr("action.auto_select"),
      variant = "outline",
      onClick = "onAutoSelect",
    }),
    ui.scroll({ height = 240, align = "stretch" }, buildRelayRows()),
  })
end

local function advancedSection()
  local children = {
    ui.button({
      text = advancedExpanded and noctalia.tr("advanced.hide") or noctalia.tr("advanced.show"),
      variant = "ghost",
      onClick = "onToggleAdvanced",
    }),
  }

  if advancedExpanded then
    table.insert(children, toggleRow("advanced.multihop", currentStatus.multihop, "onMultihop"))

    if currentStatus.multihop then
      local entryOptions = {}
      local entryCodes = {}
      local selected = 0
      for _, c in ipairs(currentStatus.relayList or {}) do
        table.insert(entryOptions, c.country)
        table.insert(entryCodes, c.code)
        if c.code == currentStatus.multihopEntry then
          selected = #entryCodes - 1
        end
      end
      table.insert(children, ui.column({ gap = 4, align = "stretch" }, {
        ui.label({ text = noctalia.tr("advanced.multihop_entry"), color = "on_surface" }),
        ui.select({ options = entryOptions, selectedIndex = selected, onChange = "onMultihopEntry" }),
      }))
    end

    local ipOptions = {
      noctalia.tr("advanced.ip_version_any"),
      noctalia.tr("advanced.ip_version_v4"),
      noctalia.tr("advanced.ip_version_v6"),
    }
    local ipValues = { "any", "v4", "v6" }
    local ipSelected = 0
    for i, v in ipairs(ipValues) do
      if v == (currentStatus.ipVersion or "any") then
        ipSelected = i - 1
        break
      end
    end
    table.insert(children, ui.column({ gap = 4, align = "stretch" }, {
      ui.label({ text = noctalia.tr("advanced.ip_version"), color = "on_surface" }),
      ui.select({ options = ipOptions, selectedIndex = ipSelected, onChange = "onIpVersion" }),
    }))
  end

  return groupBox(children)
end

local antiCensorshipModes = { "auto", "off", "wireguard-port", "udp2tcp", "shadowsocks", "quic", "lwo" }
local antiCensorshipModeLabels = {
  noctalia.tr("anti_censorship.mode_auto"),
  noctalia.tr("anti_censorship.mode_off"),
  noctalia.tr("anti_censorship.mode_wireguard_port"),
  noctalia.tr("anti_censorship.mode_udp2tcp"),
  noctalia.tr("anti_censorship.mode_shadowsocks"),
  noctalia.tr("anti_censorship.mode_quic"),
  noctalia.tr("anti_censorship.mode_lwo"),
}

local function antiCensorshipSection()
  local ac = currentStatus.antiCensorship or {}
  local mode = ac.mode or "auto"
  local selected = 0
  for i, m in ipairs(antiCensorshipModes) do
    if m == mode then
      selected = i - 1
      break
    end
  end

  local portRows = {}
  for _, method in ipairs({ "udp2tcp", "shadowsocks", "wireguard-port", "lwo" }) do
    local statusKey = method .. "Port"
    if (acPortInputs[method] or "") == "" then
      acPortInputs[method] = ac[statusKey] or ""
    end
    table.insert(portRows, ui.column({ gap = 4, align = "stretch" }, {
      ui.label({ text = noctalia.tr("anti_censorship." .. method:gsub("-", "_")), color = "on_surface" }),
      ui.input({
        key = "ac_" .. method,
        value = acPortInputs[method],
        placeholder = noctalia.tr("anti_censorship.port_placeholder"),
        onChange = function(value)
          acPortInputs[method] = if type(value) == "string" then value else ""
        end,
        onSubmit = function()
          noctalia.state.set("mullvad.command", {
            action = "setAntiCensorshipPort",
            method = method,
            port = acPortInputs[method],
          })
        end,
      }),
    }))
  end

  return groupBox({
    ui.label({ text = noctalia.tr("anti_censorship.title"), fontWeight = "bold", color = "on_surface" }),
    ui.column({ gap = 4, align = "stretch" }, {
      ui.label({ text = noctalia.tr("anti_censorship.mode"), color = "on_surface" }),
      ui.select({ options = antiCensorshipModeLabels, selectedIndex = selected, onChange = "onAntiCensorshipMode" }),
    }),
    table.unpack(portRows),
  })
end

local function dnsSection()
  local dns = currentStatus.dns or {}
  if dnsInput == "" and (dns.addresses or "") ~= "" then
    dnsInput = dns.addresses
  end

  local showCustom = dns.custom or dnsCustomDraft
  local children = {
    ui.label({ text = noctalia.tr("dns.title"), fontWeight = "bold", color = "on_surface" }),
    toggleRow("dns.custom", showCustom, "onDnsCustomToggle"),
  }

  if showCustom then
    table.insert(children, ui.column({ gap = 8, align = "stretch" }, {
      ui.input({
        key = "dns_servers",
        value = dnsInput,
        placeholder = noctalia.tr("dns.servers_placeholder"),
        onChange = function(value)
          dnsInput = if type(value) == "string" then value else ""
        end,
        onSubmit = "onDnsCustomApply",
      }),
      ui.button({ text = noctalia.tr("dns.apply"), variant = "primary", onClick = "onDnsCustomApply" }),
    }))
  else
    table.insert(children, toggleRow("dns.block_ads", dns.blockAds, "onDnsBlockAds"))
    table.insert(children, toggleRow("dns.block_trackers", dns.blockTrackers, "onDnsBlockTrackers"))
    table.insert(children, toggleRow("dns.block_malware", dns.blockMalware, "onDnsBlockMalware"))
    table.insert(children, toggleRow("dns.block_adult", dns.blockAdult, "onDnsBlockAdult"))
    table.insert(children, toggleRow("dns.block_gambling", dns.blockGambling, "onDnsBlockGambling"))
    table.insert(children, toggleRow("dns.block_social_media", dns.blockSocialMedia, "onDnsBlockSocialMedia"))
  end

  return groupBox(children)
end

-- ── Render ──

function render()
  panel.render(ui.column({ gap = 16, align = "stretch", padding = 12 }, {
    headerSection(),
    togglesSection(),
    relaySection(),
    advancedSection(),
    antiCensorshipSection(),
    dnsSection(),
  }))
end

function onOpen(_context)
  searchQuery = ""
  searchKey += 1
  confirmDisconnect = false
  noctalia.state.set("mullvad.command", { action = "refresh" })
  render()
end

-- ── Callbacks ──

function onSearchChange(value)
  searchQuery = if type(value) == "string" then value else ""
  render()
end

function onToggleAdvanced()
  advancedExpanded = not advancedExpanded
  render()
end

function onConnectClick()
  noctalia.state.set("mullvad.command", { action = "connect" })
end

function onDisconnectClick()
  local confirm = noctalia.getConfig("confirm_disconnect_in_lockdown")
  if currentStatus.locked and confirm ~= false and confirm ~= "false" then
    confirmDisconnect = true
    render()
  else
    noctalia.state.set("mullvad.command", { action = "disconnect" })
  end
end

function onConfirmDisconnect()
  confirmDisconnect = false
  noctalia.state.set("mullvad.command", { action = "disconnect" })
  render()
end

function onCancelDisconnect()
  confirmDisconnect = false
  render()
end

function onCopyIp()
  local ip = currentStatus.location and currentStatus.location.ipv4
  if ip and ip ~= "" then
    noctalia.copyToClipboard(ip, "text/plain")
  end
end

function onAutoSelect()
  noctalia.state.set("mullvad.command", {
    action = "setLocation",
    country = "",
    city = "",
    hostname = "",
    connect = noctalia.getConfig("relay_click_connects") ~= false,
  })
end

function onRefreshRelays()
  noctalia.state.set("mullvad.command", { action = "refreshRelays" })
end

function onLockdown(value)
  noctalia.state.set("mullvad.command", { action = "setLockdown", on = value == "true" })
end

function onAutoConnect(value)
  noctalia.state.set("mullvad.command", { action = "setAutoConnect", on = value == "true" })
end

function onLan(value)
  noctalia.state.set("mullvad.command", { action = "setLanSharing", allow = value == "true" })
end

function onMultihop(value)
  noctalia.state.set("mullvad.command", { action = "setMultihop", on = value == "true" })
end

function onMultihopEntry(index, _text)
  local i = (tonumber(index) or 0) + 1
  local rl = currentStatus.relayList or {}
  local country = rl[i]
  if country then
    noctalia.state.set("mullvad.command", { action = "setMultihopEntry", country = country.code })
  end
end

function onIpVersion(index, _text)
  local values = { "any", "v4", "v6" }
  local v = values[(tonumber(index) or 0) + 1]
  if v then
    noctalia.state.set("mullvad.command", { action = "setIpVersion", version = v })
  end
end

function onAntiCensorshipMode(index, _text)
  local mode = antiCensorshipModes[(tonumber(index) or 0) + 1]
  if mode then
    noctalia.state.set("mullvad.command", { action = "setAntiCensorshipMode", mode = mode })
  end
end

function onDnsCustomToggle(value)
  local dns = currentStatus.dns or {}
  if value == "true" then
    if dnsInput == "" then
      dnsCustomDraft = true
      render()
      return
    end
    dnsCustomDraft = false
    noctalia.state.set("mullvad.command", { action = "setDnsCustom", servers = dnsInput })
  else
    dnsCustomDraft = false
    noctalia.state.set("mullvad.command", { action = "setDnsDefault", blocks = dns })
  end
end

local function dnsBlocks(changedKey, value)
  local dns = currentStatus.dns or {}
  return {
    blockAds = changedKey == "blockAds" and value == "true" or dns.blockAds,
    blockTrackers = changedKey == "blockTrackers" and value == "true" or dns.blockTrackers,
    blockMalware = changedKey == "blockMalware" and value == "true" or dns.blockMalware,
    blockAdult = changedKey == "blockAdult" and value == "true" or dns.blockAdult,
    blockGambling = changedKey == "blockGambling" and value == "true" or dns.blockGambling,
    blockSocialMedia = changedKey == "blockSocialMedia" and value == "true" or dns.blockSocialMedia,
  }
end

function onDnsBlockAds(value)
  noctalia.state.set("mullvad.command", { action = "setDnsDefault", blocks = dnsBlocks("blockAds", value) })
end

function onDnsBlockTrackers(value)
  noctalia.state.set("mullvad.command", { action = "setDnsDefault", blocks = dnsBlocks("blockTrackers", value) })
end

function onDnsBlockMalware(value)
  noctalia.state.set("mullvad.command", { action = "setDnsDefault", blocks = dnsBlocks("blockMalware", value) })
end

function onDnsBlockAdult(value)
  noctalia.state.set("mullvad.command", { action = "setDnsDefault", blocks = dnsBlocks("blockAdult", value) })
end

function onDnsBlockGambling(value)
  noctalia.state.set("mullvad.command", { action = "setDnsDefault", blocks = dnsBlocks("blockGambling", value) })
end

function onDnsBlockSocialMedia(value)
  noctalia.state.set("mullvad.command", { action = "setDnsDefault", blocks = dnsBlocks("blockSocialMedia", value) })
end

function onDnsCustomApply()
  noctalia.state.set("mullvad.command", { action = "setDnsCustom", servers = dnsInput })
end

noctalia.state.watch("mullvad.status", function(value)
  currentStatus = value or {}
  confirmDisconnect = false
  if currentStatus.dns and currentStatus.dns.custom then
    dnsCustomDraft = false
  end
  render()
end)

render()
