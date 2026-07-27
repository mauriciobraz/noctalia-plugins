# Mullvad VPN

Control Mullvad VPN from the bar: connect/disconnect, pick relays, toggle lockdown mode, multihop, anti-censorship and DNS settings.

## Plugin

- ID: `noctalia/mullvad`
- Widget: `status`
- Panel: `panel`
- Service: `service`

Open the main panel:

```sh
noctalia msg panel-toggle noctalia/mullvad:panel
```

## Usage

Click the bar widget to open the panel (default) or toggle the connection. Use the panel to switch relays, change quick toggles, and configure advanced Mullvad options. Right-click a country or city in the relay list to expand it and pick a specific server.

## Features

- Connect / disconnect / reconnect with one click
- Status icon in the bar (color-coded by state)
- Optional country flag, city or IP next to the icon
- Search-first relay picker with favorites
- Right-click a country or city to expand it and pick a specific server
- Quick toggles: lockdown mode, auto-connect, LAN sharing
- Advanced: multihop with entry country, IP protocol
- Anti-censorship mode and per-method ports
- DNS: custom servers or ad/tracker/malware/adult/gambling/social-media blocking
- Account expiry warning when fewer than N days remain
- IPC handler for scripting

## Requirements

- Noctalia Shell >= 5.0
- `mullvad` CLI and `mullvad-daemon` running
- An active Mullvad account

## Settings

| Setting                          | Default | Description                                              |
| -------------------------------- | ------- | -------------------------------------------------------- |
| `refresh_interval`               | 3000    | Status poll interval (ms)                                |
| `show_country_flag`              | true    | Show flag emoji in the bar widget                        |
| `show_city_name`                 | false   | Show city next to the icon                               |
| `show_ip`                        | false   | Show current IP next to the icon                         |
| `compact_mode`                   | false   | Icon only, no adornments                                 |
| `click_action`                   | panel   | Left-click: `toggle` or open `panel`                     |
| `relay_click_connects`           | true    | Selecting a relay row connects immediately               |
| `confirm_disconnect_in_lockdown` | true    | Ask before disconnecting with lockdown on                |
| `favorite_countries`             | ""      | Comma-separated 2-letter country codes pinned to the top |
| `expiry_warning_days`            | 7       | Threshold for the expiry banner                          |

## IPC

```sh
noctalia msg plugin noctalia/mullvad:status toggle
noctalia msg plugin noctalia/mullvad:status connect
noctalia msg plugin noctalia/mullvad:status disconnect
noctalia msg plugin noctalia/mullvad:status setLocation se sto
noctalia msg plugin noctalia/mullvad:status setLockdown true
```

## License

MIT
