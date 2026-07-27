--!nonstrict
-- Mullvad VPN service.
--
-- Polls the Mullvad CLI and publishes a single shared status object. The bar
-- widget and panel read `mullvad.status` and drive actions by writing to the
-- `mullvad.command` state key.

local DEFAULT_REFRESH_INTERVAL = 3000
local ACCOUNT_INTERVAL_TICKS = 100
local TOGGLES_INTERVAL_TICKS = 10

local tickCount = 0
local statusInFlight = false

local status = {
  installed = false,
  state = "disconnected",
  locked = false,
  location = nil,
  visibleLocation = nil,
  relaySelection = { country = "", city = "", hostname = "" },
  multihop = false,
  multihopEntry = "",
  ipVersion = "any",
  lockdownMode = false,
  autoConnect = false,
  lanSharing = "allow",
  accountExpiry = "",
  accountDaysLeft = 9999,
  relayList = {},
  relayListReady = false,
  favoriteCountries = {},
}

local function cfg(key)
  return noctalia.getConfig(key)
end

local function shellQuote(s)
  return "'" .. tostring(s):gsub("'", "'\\''") .. "'"
end

local function log(msg)
  noctalia.log(`mullvad: {msg}`)
end

local function trim(s)
  return noctalia.string.trim(s)
end

local function truthy(v)
  return v == true or v == "true" or v == "on" or v == 1
end

local function publish()
  noctalia.state.set("mullvad.status", {
    installed = status.installed,
    state = status.state,
    locked = status.locked,
    location = status.location,
    visibleLocation = status.visibleLocation,
    relaySelection = status.relaySelection,
    multihop = status.multihop,
    multihopEntry = status.multihopEntry,
    ipVersion = status.ipVersion,
    lockdownMode = status.lockdownMode,
    autoConnect = status.autoConnect,
    lanSharing = status.lanSharing,
    accountExpiry = status.accountExpiry,
    accountDaysLeft = status.accountDaysLeft,
    relayList = status.relayList,
    relayListReady = status.relayListReady,
    favoriteCountries = status.favoriteCountries,
  })
end

local function parseFavoriteCountries()
  local s = cfg("favorite_countries")
  if type(s) ~= "string" or s == "" then
    return {}
  end
  local out = {}
  for part in s:gmatch("[^,]+") do
    local code = trim(part):lower()
    if #code == 2 then
      table.insert(out, code)
    end
  end
  return out
end

local function applyRefreshInterval()
  local interval = cfg("refresh_interval")
  if type(interval) ~= "number" or interval < 1000 then
    interval = DEFAULT_REFRESH_INTERVAL
  end
  noctalia.setUpdateInterval(math.floor(interval))
end

-- ── Date parsing ──

local function parseIsoDate(s)
  local y, m, d, H, M, S = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)[T ](%d%d):(%d%d):?(%d*)")
  if y then
    return os.time({
      year = tonumber(y),
      month = tonumber(m),
      day = tonumber(d),
      hour = tonumber(H),
      min = tonumber(M),
      sec = tonumber(S) or 0,
    })
  end
  y, m, d = s:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)")
  if y then
    return os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 0, min = 0, sec = 0 })
  end
  return nil
end

-- ── Command builders ──

local function runMullvad(args, onResult, timeoutMs)
  local parts = { "mullvad" }
  for _, arg in ipairs(args) do
    table.insert(parts, shellQuote(arg))
  end
  return noctalia.runAsync(table.concat(parts, " "), onResult, timeoutMs)
end

-- ── Status polling ──

local function stateFromString(s)
  if s == "connected" then return "connected" end
  if s == "connecting" then return "connecting" end
  if s == "disconnecting" then return "disconnecting" end
  if s == "disconnected" then return "disconnected" end
  if s == "error" then return "error" end
  return "error"
end

local function parseStatusJson(stdout)
  local data, err = noctalia.json.decode(stdout)
  if err ~= nil or type(data) ~= "table" then
    return nil
  end
  local out = {
    state = stateFromString(data.state),
    locked = false,
    location = nil,
    visibleLocation = nil,
  }
  local details = data.details
  if type(details) == "table" then
    out.locked = details.locked_down == true
    local loc = details.location
    if type(loc) == "table" then
      if out.state == "connected" then
        out.location = {
          country = loc.country or "",
          city = loc.city or "",
          hostname = loc.hostname or "",
          ipv4 = loc.ipv4 or (type(details.endpoint) == "table" and details.endpoint.address) or "",
          ipv6 = loc.ipv6 or "",
          mullvad_exit_ip = loc.mullvad_exit_ip == true,
        }
      else
        out.visibleLocation = {
          country = loc.country or "",
          city = loc.city or "",
          ipv4 = loc.ipv4 or "",
          ipv6 = loc.ipv6 or "",
        }
      end
    end
  end
  return out
end

local function updateStatus()
  if not status.installed or statusInFlight then
    return
  end
  statusInFlight = true
  runMullvad({ "status", "--json" }, function(result)
    statusInFlight = false
    if result == nil or result.exitCode ~= 0 then
      status.state = "error"
      status.locked = false
      status.location = nil
      status.visibleLocation = nil
      publish()
      return
    end
    local parsed = parseStatusJson(result.stdout)
    if parsed == nil then
      status.state = "error"
      publish()
      return
    end
    status.state = parsed.state
    status.locked = parsed.locked
    status.location = parsed.location
    status.visibleLocation = parsed.visibleLocation
    publish()
  end, 10000)
end

local function scheduleStatusRefresh()
  noctalia.runAsync("sleep 0.5", function()
    if status.installed then
      updateStatus()
    end
  end)
end

-- ── Relay selection ──

local function parseRelayGet(stdout)
  local out = {
    country = "", city = "", hostname = "",
    multihop = false, multihopEntry = "", ipVersion = "any",
  }
  for rawLine in (stdout or ""):gmatch("[^\r\n]+") do
    local line = trim(rawLine)
    local country = line:match("^Location:%s+country%s+(%S+)")
    if country then
      out.country = country
      continue
    end
    local cityCountry, cityCode = line:match("^Location:%s+city%s+(%S+)%s+(%S+)")
    if cityCountry then
      out.country = cityCountry
      out.city = cityCode
      continue
    end
    local hostCountry, hostCity, hostName = line:match("^Location:%s+hostname%s+(%S+)%s+(%S+)%s+(%S+)")
    if hostCountry then
      out.country = hostCountry
      out.city = hostCity
      out.hostname = hostName
      continue
    end
    local entry = line:match("^Multihop entry:%s+country%s+(%S+)")
    if entry then
      out.multihopEntry = entry
      continue
    end
    local mh = line:match("^Multihop state:%s+(%w+)")
    if mh then
      out.multihop = mh:lower() == "enabled"
      continue
    end
    local ip = line:match("^IP protocol:%s+(%S+)")
    if ip then
      local v = ip:lower()
      out.ipVersion = (v == "v4" or v == "v6") and v or "any"
    end
  end
  return out
end

local function refreshRelaySelection()
  if not status.installed then
    return
  end
  runMullvad({ "relay", "get" }, function(result)
    if result == nil or result.exitCode ~= 0 then
      return
    end
    local parsed = parseRelayGet(result.stdout)
    status.relaySelection = {
      country = parsed.country,
      city = parsed.city,
      hostname = parsed.hostname,
    }
    status.multihop = parsed.multihop
    status.multihopEntry = parsed.multihopEntry
    status.ipVersion = parsed.ipVersion
    publish()
  end, 10000)
end

-- ── Relay list ──

local function parseRelayList(stdout)
  local out = {}
  local country = nil
  local city = nil
  for line in (stdout or ""):gmatch("[^\r\n]+") do
    if trim(line) == "" then
      country = nil
      city = nil
      continue
    end
    local countryName, countryCode = line:match("^([^\t].-)%s+%(([a-z][a-z])%)%s*$")
    if countryName and countryCode then
      country = { country = countryName, code = countryCode, cities = {} }
      table.insert(out, country)
      city = nil
      continue
    end
    local cityName, cityCode = line:match("^\t([^\t].-)%s+%(([a-z0-9]+)%)")
    if cityName and cityCode and country then
      city = { city = cityName, code = cityCode, hostnames = {} }
      table.insert(country.cities, city)
      continue
    end
    local hostName, hostIp = line:match("^\t\t(%S+)%s+%(([^,%)]+)")
    if hostName and hostIp and city then
      table.insert(city.hostnames, { name = hostName, ipv4 = trim(hostIp) })
    end
  end
  return out
end

local function refreshRelayList()
  if not status.installed then
    return
  end
  runMullvad({ "relay", "list" }, function(result)
    if result == nil or result.exitCode ~= 0 then
      return
    end
    status.relayList = parseRelayList(result.stdout)
    status.relayListReady = true
    publish()
  end, 60000)
end

-- ── Quick toggles ──

local function parseOnOff(stdout)
  local raw = trim(stdout or ""):lower()
  return raw:match(":%s*on") ~= nil or raw:match("^on$") ~= nil
end

local function parseLan(stdout)
  local raw = trim(stdout or ""):lower()
  return raw:find("block", 1, true) and "block" or "allow"
end

local function refreshTogglesState()
  if not status.installed then
    return
  end
  runMullvad({ "lockdown-mode", "get" }, function(result)
    if result and result.exitCode == 0 then
      status.lockdownMode = parseOnOff(result.stdout)
      publish()
    end
  end, 10000)
  runMullvad({ "auto-connect", "get" }, function(result)
    if result and result.exitCode == 0 then
      status.autoConnect = parseOnOff(result.stdout)
      publish()
    end
  end, 10000)
  runMullvad({ "lan", "get" }, function(result)
    if result and result.exitCode == 0 then
      status.lanSharing = parseLan(result.stdout)
      publish()
    end
  end, 10000)
end

-- ── Account expiry ──

local function refreshAccount()
  if not status.installed then
    return
  end
  runMullvad({ "account", "get" }, function(result)
    if result == nil or result.exitCode ~= 0 then
      return
    end
    local expiry = result.stdout:match("Expires at:%s+(%S+)")
    if expiry == nil then
      return
    end
    status.accountExpiry = expiry
    local exp = parseIsoDate(expiry)
    if exp ~= nil then
      status.accountDaysLeft = math.floor((exp - os.time()) / 86400)
    end
    publish()
  end, 10000)
end

-- ── Actions ──

local function notifyLockdownChange(active)
  noctalia.notify(
    noctalia.tr("toast.title"),
    active and noctalia.tr("toast.lockdown_on") or noctalia.tr("toast.lockdown_off")
  )
end

local function setLocation(countryCode, cityCode, hostname, autoConnect)
  if not status.installed then
    return
  end
  local args = { "relay", "set", "location" }
  if countryCode and countryCode ~= "" then
    table.insert(args, countryCode)
    if cityCode and cityCode ~= "" then
      table.insert(args, cityCode)
      if hostname and hostname ~= "" then
        table.insert(args, hostname)
      end
    end
  end
  runMullvad(args, function(result)
    refreshRelaySelection()
    if autoConnect then
      noctalia.state.set("mullvad.command", { action = "connect" })
    else
      scheduleStatusRefresh()
    end
  end, 10000)
end

local function connectVpn()
  if not status.installed then
    return
  end
  runMullvad({ "connect" }, function(result)
    if result and result.exitCode == 0 then
      noctalia.notify(noctalia.tr("toast.title"), noctalia.tr("toast.connected"))
    else
      noctalia.notifyError(noctalia.tr("toast.title"), noctalia.tr("toast.connect_failed"))
    end
    scheduleStatusRefresh()
  end, 30000)
end

local function disconnectVpn()
  if not status.installed then
    return
  end
  runMullvad({ "disconnect" }, function(result)
    if result and result.exitCode == 0 then
      noctalia.notify(noctalia.tr("toast.title"), noctalia.tr("toast.disconnected"))
    end
    scheduleStatusRefresh()
  end, 30000)
end

local function reconnectVpn()
  if not status.installed then
    return
  end
  runMullvad({ "reconnect" }, function()
    scheduleStatusRefresh()
  end, 30000)
end

local function toggleVpn()
  if status.state == "connected" or status.state == "connecting" then
    disconnectVpn()
  else
    connectVpn()
  end
end

local function setLockdown(on)
  if not status.installed then
    return
  end
  runMullvad({ "lockdown-mode", "set", on and "on" or "off" }, function(result)
    if result and result.exitCode == 0 then
      notifyLockdownChange(on)
    end
    refreshTogglesState()
  end, 10000)
end

local function setAutoConnect(on)
  if not status.installed then
    return
  end
  runMullvad({ "auto-connect", "set", on and "on" or "off" }, refreshTogglesState, 10000)
end

local function setLanSharing(allow)
  if not status.installed then
    return
  end
  runMullvad({ "lan", "set", allow and "allow" or "block" }, refreshTogglesState, 10000)
end

local function setMultihop(on)
  if not status.installed then
    return
  end
  runMullvad({ "relay", "set", "multihop", on and "on" or "off" }, refreshRelaySelection, 10000)
end

local function setMultihopEntry(countryCode)
  if not status.installed or not countryCode or countryCode == "" then
    return
  end
  runMullvad({ "relay", "set", "entry", "location", countryCode }, refreshRelaySelection, 10000)
end

local function setIpVersion(v)
  if not status.installed or not v or v == "" then
    return
  end
  runMullvad({ "relay", "set", "ip-version", v }, refreshRelaySelection, 10000)
end

local function refreshAll()
  updateStatus()
  refreshRelaySelection()
  refreshTogglesState()
  refreshAccount()
  refreshRelayList()
end

-- ── Commands from UI ──

noctalia.state.watch("mullvad.command", function(cmd)
  if type(cmd) ~= "table" then
    return
  end
  local action = cmd.action
  if action == "connect" then
    connectVpn()
  elseif action == "disconnect" then
    disconnectVpn()
  elseif action == "reconnect" then
    reconnectVpn()
  elseif action == "toggle" then
    toggleVpn()
  elseif action == "setLocation" then
    setLocation(cmd.country, cmd.city, cmd.hostname, cmd.connect)
  elseif action == "setLockdown" then
    setLockdown(truthy(cmd.on))
  elseif action == "setAutoConnect" then
    setAutoConnect(truthy(cmd.on))
  elseif action == "setLanSharing" then
    setLanSharing(truthy(cmd.allow))
  elseif action == "setMultihop" then
    setMultihop(truthy(cmd.on))
  elseif action == "setMultihopEntry" then
    setMultihopEntry(cmd.country)
  elseif action == "setIpVersion" then
    setIpVersion(cmd.version)
  elseif action == "refresh" then
    refreshAll()
  elseif action == "refreshRelays" then
    refreshRelayList()
  end
end)

-- ── Lifecycle ──

function update()
  tickCount += 1
  if not status.installed then
    status.installed = noctalia.commandExists("mullvad")
    if status.installed then
      publish()
      refreshAll()
    end
    return
  end

  updateStatus()
  if tickCount % TOGGLES_INTERVAL_TICKS == 0 then
    refreshTogglesState()
    refreshRelaySelection()
  end
  if tickCount % ACCOUNT_INTERVAL_TICKS == 0 then
    refreshAccount()
  end
end

function onConfigChanged()
  applyRefreshInterval()
  status.favoriteCountries = parseFavoriteCountries()
  publish()
end

-- Bootstrap
status.installed = noctalia.commandExists("mullvad")
status.favoriteCountries = parseFavoriteCountries()
applyRefreshInterval()
publish()
if status.installed then
  refreshAll()
else
  status.state = "error"
  publish()
end
