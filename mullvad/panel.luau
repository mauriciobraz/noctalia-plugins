--!nonstrict
-- Mullvad VPN panel.
--
-- Relay picker, quick toggles, multihop/IP settings and connection controls.
-- Reads the shared `mullvad.status` state published by the service.

local currentStatus = noctalia.state.get("mullvad.status") or {}
local searchQuery = ""
local searchInputKey = 0
local advancedExpanded = false
local confirmDisconnect = false

local expandedCountries = {}
local expandedCities = {}

local antiCensorshipInputs = { udp2tcp = "", shadowsocks = "", wireguard = "", lwo = "" }
local dnsServersInput = ""
local dnsCustomDraft = false

-- Populated during render so the global select callbacks can map indices back
-- to values without capturing state in closures.
local entryOptions = {}
local entryCodes = {}
local ipVersionLabels = {}
local ipVersionValues = {}

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

local function updateSelectOptions()
  entryOptions = {}
  entryCodes = {}
  for _, c in ipairs(currentStatus.relayList or {}) do
    table.insert(entryOptions, c.country)
    table.insert(entryCodes, c.code)
  end

  ipVersionLabels = {
    noctalia.tr("advanced.ip_version_any"),
    noctalia.tr("advanced.ip_version_v4"),
    noctalia.tr("advanced.ip_version_v6"),
  }
  ipVersionValues = { "any", "v4", "v6" }
end

-- ── Relay list ──

local function buildRows()
  local query = noctalia.string.trim(searchQuery):lower()
  local searching = query ~= ""
  local rl = currentStatus.relayList or {}
  local fav = currentStatus.favoriteCountries or {}
  local sel = currentStatus.relaySelection or { country = "", city = "", hostname = "" }

  local function matches(country, city, host)
    if searching then
      local hay = country.country .. " " .. country.code
      if city then
        hay = hay .. " " .. city.city .. " " .. city.code
      end
      if host then
        hay = hay .. " " .. host.name
      end
      return string.find(hay:lower(), query, 1, true) ~= nil
    end
    return true
  end

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
  for _, c in ipairs(ordered) do
    local countryExpanded = expandedCountries[c.code] == true
    local countryMatches = matches(c, nil, nil)
    local cityMatches = false
    local hostMatches = false
    for _, ci in ipairs(c.cities) do
      if matches(c, ci, nil) then
        cityMatches = true
      end
      for _, h in ipairs(ci.hostnames) do
        if matches(c, ci, h) then
          hostMatches = true
        end
      end
    end
    if not countryMatches and not cityMatches and not hostMatches and not countryExpanded then
      continue
    end

    local totalHosts = 0
    for _, ci in ipairs(c.cities) do
      totalHosts += #ci.hostnames
    end
    table.insert(rows, {
      kind = "country",
      label = flagEmoji(c.code) .. " " .. c.country,
      countryCode = c.code,
      cityCode = "",
      hostname = "",
      isCurrent = sel.country == c.code and sel.city == "",
      count = totalHosts,
      expanded = countryExpanded,
      canExpand = true,
    })

    if not searching and not countryExpanded then
      continue
    end

    for _, ci in ipairs(c.cities) do
      local cityKey = c.code .. ":" .. ci.code
      local cityExpanded = expandedCities[cityKey] == true
      local cityHostMatches = false
      for _, h in ipairs(ci.hostnames) do
        if matches(c, ci, h) then
          cityHostMatches = true
        end
      end
      if not matches(c, ci, nil) and not cityHostMatches and not cityExpanded then
        continue
      end

      table.insert(rows, {
        kind = "city",
        label = "  " .. flagEmoji(c.code) .. " " .. ci.city,
        countryCode = c.code,
        cityCode = ci.code,
        hostname = "",
        isCurrent = sel.country == c.code and sel.city == ci.code and sel.hostname == "",
        count = #ci.hostnames,
        expanded = cityExpanded,
        canExpand = true,
      })

      if not searching and not cityExpanded then
        continue
      end

      for _, h in ipairs(ci.hostnames) do
        if searching and not matches(c, ci, h) then
          continue
        end
        table.insert(rows, {
          kind = "host",
          label = "    " .. h.name .. "  " .. h.ipv4,
          countryCode = c.code,
          cityCode = ci.code,
          hostname = h.name,
          isCurrent = sel.hostname == h.name,
          count = 0,
          canExpand = false,
        })
      end
    end
  end
  return rows
end

local function activateRow(row)
  noctalia.state.set("mullvad.command", {
    action = "setLocation",
    country = row.countryCode,
    city = row.cityCode,
    hostname = row.hostname,
    connect = noctalia.getConfig("relay_click_connects") ~= false,
  })
end

local function toggleExpandRow(row)
  if row.kind == "country" then
    if expandedCountries[row.countryCode] then
      expandedCountries[row.countryCode] = nil
    else
      expandedCountries[row.countryCode] = true
    end
  elseif row.kind == "city" then
    local key = row.countryCode .. ":" .. row.cityCode
    if expandedCities[key] then
      expandedCities[key] = nil
    else
      expandedCities[key] = true
    end
  end
  render()
end

local function relayRow(row)
  local expandGlyph = row.expanded and "chevron-up" or "chevron-down"
  return ui.row({
    gap = 8,
    align = "center",
    padding = 8,
    fill = row.isCurrent and "primary" or nil,
    onClick = function()
      activateRow(row)
    end,
    onRightClick = row.kind == "country" and function()
      noctalia.state.set("mullvad.menuTarget", {
        countryCode = row.countryCode,
        countryName = countryName(row.countryCode),
      })
      noctalia.togglePanel("noctalia/mullvad:relay-menu")
    end or (row.canExpand and function()
      toggleExpandRow(row)
    end or nil),
  }, {
    ui.label({
      text = row.label,
      color = row.isCurrent and "on_primary" or "on_surface",
      flexGrow = 1,
    }),
    if row.count and row.count > 0
      then ui.label({ text = tostring(row.count), color = row.isCurrent and "on_primary" or "on_surface_variant" })
      else ui.box({ width = 0 }),
    if row.canExpand
      then ui.button({
        glyph = expandGlyph,
        variant = "ghost",
        tooltip = noctalia.tr("relay.expand_tooltip"),
        onClick = function()
          toggleExpandRow(row)
        end,
      })
      else ui.box({ width = 0 }),
  })
end

-- ── Sections ──

local function expiryBanner()
  local installed = currentStatus.installed == true
  local days = currentStatus.accountDaysLeft or 9999
  local threshold = noctalia.getConfig("expiry_warning_days")
  if type(threshold) ~= "number" then
    threshold = 7
  end
  if not installed or days > threshold then
    return ui.box({ width = 0, height = 0 })
  end
  local text = if days <= 0
    then noctalia.tr("account.expired")
    else noctalia.tr("account.expires_in", { days = days })
  return ui.box({ fill = "error", radius = 8, padding = 10 }, {
    ui.label({ text = text, color = "on_error", wrap = true }),
  })
end

local function headerSection()
  local installed = currentStatus.installed == true
  local vpnState = currentStatus.state or "disconnected"
  local locked = currentStatus.locked == true
  local location = currentStatus.location
  local selection = currentStatus.relaySelection or { country = "", city = "", hostname = "" }

  local glyph = installed and "shield" or "shield-off"
  local color = if not installed
    then "error"
    elseif vpnState == "connected" then "primary"
    elseif locked then "error"
    else "on_surface"

  local stateText
  if not installed then
    stateText = noctalia.tr("state.not_installed")
  elseif vpnState == "error" then
    stateText = noctalia.tr("state.error")
  elseif locked and vpnState ~= "connected" then
    stateText = noctalia.tr("state.blocked")
  else
    stateText = noctalia.tr("state." .. vpnState)
  end

  local details = {}
  if vpnState == "connected" and location and location.country ~= "" then
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
    if currentStatus.multihopEntry ~= "" then
      table.insert(
        details,
        noctalia.tr("badges.multihop_via", { country = countryName(currentStatus.multihopEntry) })
      )
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
  if vpnState == "connected" then
    buttonText = noctalia.tr("action.disconnect")
  elseif vpnState == "connecting" then
    buttonText = noctalia.tr("action.cancel")
  else
    buttonText = noctalia.tr("action.connect")
  end

  return ui.column({ gap = 12, align = "stretch" }, {
    ui.row({ gap = 16, align = "center" }, {
      ui.glyph({ name = glyph, color = color, fontSize = 32 }),
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
    if confirmDisconnect
      then ui.column({ gap = 8, align = "stretch" }, {
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
      })
      else ui.button({
        text = buttonText,
        variant = if vpnState == "connected" or vpnState == "connecting" then "destructive" else "primary",
        enabled = installed,
        onClick = if vpnState == "connected" or vpnState == "connecting"
          then "onDisconnectClick"
          else "onConnectClick",
      }),
    expiryBanner(),
  })
end

local function toggleRow(labelKey, tooltipKey, checked, callback)
  return ui.row({ gap = 12, align = "center", justify = "space_between" }, {
    ui.column({ gap = 2, flexGrow = 1, align = "stretch" }, {
      ui.label({ text = noctalia.tr(labelKey), fontWeight = "medium", color = "on_surface" }),
      ui.label({ text = noctalia.tr(tooltipKey), color = "on_surface_variant" }),
    }),
    ui.toggle({ checked = checked, onChange = callback }),
  })
end

local function groupBox(children)
  return ui.box({ fill = "surface_variant/0.4", radius = 8, padding = 12 }, {
    ui.column({ gap = 12, align = "stretch", flexGrow = 1 }, children),
  })
end

local function togglesSection()
  return groupBox({
    toggleRow("toggles.lockdown", "toggles.lockdown_tooltip", currentStatus.lockdownMode, "onLockdown"),
    toggleRow("toggles.auto_connect", "toggles.auto_connect_tooltip", currentStatus.autoConnect, "onAutoConnect"),
    toggleRow("toggles.lan", "toggles.lan_tooltip", currentStatus.lanSharing == "allow", "onLan"),
  })
end

local function relaySection()
  local rows = buildRows()
  local rowNodes = {}
  for _, row in ipairs(rows) do
    table.insert(rowNodes, relayRow(row))
  end
  if #rowNodes == 0 then
    table.insert(
      rowNodes,
      ui.row({ padding = 12 }, {
        ui.label({
          text = if currentStatus.relayListReady
            then noctalia.tr("relay.no_results")
            else noctalia.tr("relay.loading"),
          color = "on_surface_variant",
        }),
      })
    )
  end

  return groupBox({
    ui.row({ gap = 8, align = "center" }, {
      ui.input({
        key = "relay_search_" .. tostring(searchInputKey),
        value = searchQuery,
        placeholder = noctalia.tr("relay.search_placeholder"),
        onChange = "onSearchChange",
        flexGrow = 1,
      }),
      ui.button({
        glyph = "refresh",
        variant = "outline",
        onClick = "onRefreshRelays",
        tooltip = noctalia.tr("action.refresh_relays"),
      }),
    }),
    ui.button({ text = noctalia.tr("action.auto_select"), variant = "outline", onClick = "onAutoSelect" }),
    ui.scroll({ flexGrow = 1, align = "stretch" }, rowNodes),
  })
end

local function multihopEntrySelect()
  local selectedIndex = 0
  for i, code in ipairs(entryCodes) do
    if code == currentStatus.multihopEntry then
      selectedIndex = i - 1
      break
    end
  end
  return ui.select({ options = entryOptions, selectedIndex = selectedIndex, onChange = "onMultihopEntry" })
end

local function ipVersionSelect()
  local selectedIndex = 0
  for i, v in ipairs(ipVersionValues) do
    if v == currentStatus.ipVersion then
      selectedIndex = i - 1
      break
    end
  end
  return ui.select({ options = ipVersionLabels, selectedIndex = selectedIndex, onChange = "onIpVersion" })
end

local function advancedSection()
  return ui.column({ gap = 12, align = "stretch" }, {
    ui.button({
      text = advancedExpanded and noctalia.tr("advanced.hide") or noctalia.tr("advanced.show"),
      variant = "ghost",
      onClick = "onToggleAdvanced",
    }),
    if advancedExpanded
      then ui.column({ gap = 12, align = "stretch" }, {
        toggleRow("advanced.multihop", "advanced.multihop_tooltip", currentStatus.multihop, "onMultihop"),
        if currentStatus.multihop
          then ui.column({ gap = 4, align = "stretch" }, {
            ui.label({ text = noctalia.tr("advanced.multihop_entry"), color = "on_surface" }),
            multihopEntrySelect(),
          })
          else ui.box({ width = 0, height = 0 }),
        ui.column({ gap = 4, align = "stretch" }, {
          ui.label({ text = noctalia.tr("advanced.ip_version"), color = "on_surface" }),
          ipVersionSelect(),
        }),
      })
      else ui.box({ width = 0, height = 0 }),
  })
end

-- ── Anti-censorship ──

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

local function antiCensorshipModeSelect()
  local selectedIndex = 0
  for i, m in ipairs(antiCensorshipModes) do
    if m == currentStatus.antiCensorship.mode then
      selectedIndex = i - 1
      break
    end
  end
  return ui.select({ options = antiCensorshipModeLabels, selectedIndex = selectedIndex, onChange = "onAntiCensorshipMode" })
end

local function antiCensorshipPortRow(labelKey, method)
  return ui.column({ gap = 4, align = "stretch" }, {
    ui.label({ text = noctalia.tr(labelKey), color = "on_surface" }),
    ui.input({
      key = "ac_" .. method,
      value = antiCensorshipInputs[method] or "",
      placeholder = noctalia.tr("anti_censorship.port_placeholder"),
      onChange = function(value)
        antiCensorshipInputs[method] = if type(value) == "string" then value else ""
      end,
      onSubmit = function()
        noctalia.state.set("mullvad.command", { action = "setAntiCensorshipPort", method = method, port = antiCensorshipInputs[method] })
      end,
    }),
  })
end

local function antiCensorshipSection()
  return groupBox({
    ui.label({ text = noctalia.tr("anti_censorship.title"), fontWeight = "bold", color = "on_surface" }),
    ui.column({ gap = 4, align = "stretch" }, {
      ui.label({ text = noctalia.tr("anti_censorship.mode"), color = "on_surface" }),
      antiCensorshipModeSelect(),
    }),
    antiCensorshipPortRow("anti_censorship.udp2tcp", "udp2tcp"),
    antiCensorshipPortRow("anti_censorship.shadowsocks", "shadowsocks"),
    antiCensorshipPortRow("anti_censorship.wireguard_port", "wireguard-port"),
    antiCensorshipPortRow("anti_censorship.lwo", "lwo"),
  })
end

-- ── DNS ──

local function dnsBlockToggle(labelKey, checked, callback)
  return ui.row({ gap = 12, align = "center", justify = "space_between" }, {
    ui.label({ text = noctalia.tr(labelKey), fontWeight = "medium", color = "on_surface" }),
    ui.toggle({ checked = checked, onChange = callback }),
  })
end

local function dnsSection()
  local dns = currentStatus.dns or {}
  local showCustom = dns.custom or dnsCustomDraft
  local children = {
    ui.label({ text = noctalia.tr("dns.title"), fontWeight = "bold", color = "on_surface" }),
    ui.row({ gap = 12, align = "center", justify = "space_between" }, {
      ui.column({ gap = 2, flexGrow = 1 }, {
        ui.label({ text = noctalia.tr("dns.custom"), fontWeight = "medium", color = "on_surface" }),
      }),
      ui.toggle({ checked = showCustom, onChange = "onDnsCustomToggle" }),
    }),
  }

  if showCustom then
    table.insert(children, ui.column({ gap = 8, align = "stretch" }, {
      ui.input({
        key = "dns_servers",
        value = dnsServersInput,
        placeholder = noctalia.tr("dns.servers_placeholder"),
        onChange = function(value)
          dnsServersInput = if type(value) == "string" then value else ""
        end,
        onSubmit = "onDnsCustomApply",
      }),
      ui.button({ text = noctalia.tr("dns.apply"), variant = "primary", onClick = "onDnsCustomApply" }),
    }))
  else
    table.insert(children, dnsBlockToggle("dns.block_ads", dns.blockAds, "onDnsBlockAds"))
    table.insert(children, dnsBlockToggle("dns.block_trackers", dns.blockTrackers, "onDnsBlockTrackers"))
    table.insert(children, dnsBlockToggle("dns.block_malware", dns.blockMalware, "onDnsBlockMalware"))
    table.insert(children, dnsBlockToggle("dns.block_adult", dns.blockAdult, "onDnsBlockAdult"))
    table.insert(children, dnsBlockToggle("dns.block_gambling", dns.blockGambling, "onDnsBlockGambling"))
    table.insert(children, dnsBlockToggle("dns.block_social_media", dns.blockSocialMedia, "onDnsBlockSocialMedia"))
  end

  return groupBox(children)
end

-- ── Render ──

function render()
  updateSelectOptions()

  local ac = currentStatus.antiCensorship or {}
  local acPorts = {
    udp2tcp = "udp2tcpPort",
    shadowsocks = "shadowsocksPort",
    ["wireguard-port"] = "wireguardPort",
    lwo = "lwoPort",
  }
  for method, portKey in pairs(acPorts) do
    if (antiCensorshipInputs[method] or "") == "" then
      antiCensorshipInputs[method] = ac[portKey] or ""
    end
  end

  local dns = currentStatus.dns or {}
  if dnsServersInput == "" and (dns.addresses or "") ~= "" then
    dnsServersInput = dns.addresses
  end

  panel.render(ui.column({ flexGrow = 1, gap = 16, align = "stretch" }, {
    ui.scroll({ flexGrow = 1, gap = 16, align = "stretch" }, {
      headerSection(),
      togglesSection(),
      relaySection(),
      advancedSection(),
      antiCensorshipSection(),
      dnsSection(),
    }),
  }))
end

-- ── Callbacks ──

function onOpen(_context)
  searchQuery = ""
  searchInputKey += 1
  confirmDisconnect = false
  noctalia.state.set("mullvad.command", { action = "refresh" })
  render()
end

function onSearchChange(value)
  searchQuery = if type(value) == "string" then value else ""
  render()
end

function onToggleAdvanced()
  advancedExpanded = not advancedExpanded
  render()
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
  local code = entryCodes[i]
  if code then
    noctalia.state.set("mullvad.command", { action = "setMultihopEntry", country = code })
  end
end

function onIpVersion(index, _text)
  local i = (tonumber(index) or 0) + 1
  local v = ipVersionValues[i]
  if v then
    noctalia.state.set("mullvad.command", { action = "setIpVersion", version = v })
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

function onCopyIp()
  local ip = currentStatus.location and currentStatus.location.ipv4
  if ip and ip ~= "" then
    noctalia.copyToClipboard(ip, "text/plain")
  end
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

function onAntiCensorshipMode(index, _text)
  local i = (tonumber(index) or 0) + 1
  local mode = antiCensorshipModes[i]
  if mode then
    noctalia.state.set("mullvad.command", { action = "setAntiCensorshipMode", mode = mode })
  end
end

function onDnsCustomToggle(value)
  local dns = currentStatus.dns or {}
  if value == "true" then
    if dnsServersInput == "" then
      dnsCustomDraft = true
      render()
      return
    end
    dnsCustomDraft = false
    noctalia.state.set("mullvad.command", { action = "setDnsCustom", servers = dnsServersInput })
  else
    dnsCustomDraft = false
    noctalia.state.set("mullvad.command", { action = "setDnsDefault", blocks = dns })
  end
end

local function dnsBlocks(changedKey, value)
  local dns = currentStatus.dns or {}
  local blocks = {
    blockAds = dns.blockAds,
    blockTrackers = dns.blockTrackers,
    blockMalware = dns.blockMalware,
    blockAdult = dns.blockAdult,
    blockGambling = dns.blockGambling,
    blockSocialMedia = dns.blockSocialMedia,
  }
  blocks[changedKey] = value == "true"
  return blocks
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
  noctalia.state.set("mullvad.command", { action = "setDnsCustom", servers = dnsServersInput })
end

noctalia.state.watch("mullvad.status", function(value)
  currentStatus = value
  confirmDisconnect = false
  if currentStatus.dns and currentStatus.dns.custom then
    dnsCustomDraft = false
  end
  render()
end)

render()
