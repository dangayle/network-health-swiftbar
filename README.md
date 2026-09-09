# network-health-swiftbar

A [SwiftBar](https://swiftbar.app/) plugin that tells you which layer of your network is the problem — before you blame the website.

The menu bar shows live round-trip time to your router with a color verdict:

| Menu bar | Meaning |
| --- | --- |
| `● 8ms` green | Local Wi-Fi, ISP hop, and internet references are all healthy. A slow page is the site's problem. |
| `● 8ms` yellow | The ISP hop or upstream is degraded. The site may look slow, but it is not the site's fault. |
| `● 8ms` red | Your local Wi-Fi link is degraded. Retest before blaming the site. |
| `● —` gray | No data (usually no default route). |

## How it works

The plugin measures three layers in parallel, each one segment further along the path:

1. **Router** — ICMP ping to your default gateway. Covers only your Wi-Fi and local LAN.
2. **ISP first hop** — the first node past your router, measured with traceroute TTL-exceeded probes because some ISP hops (e.g. CGNAT gateways) ignore ICMP echo.
3. **Internet references** — ICMP ping to Cloudflare (`1.1.1.1`) and Google (`8.8.8.8`), which travel through your ISP.

Clicking the menu bar item shows per-layer RTT and packet loss, plus a one-click macOS `networkQuality` test.

The classification logic, in order:

- Router loss or RTT above threshold → **red** (local Wi-Fi degraded)
- ISP hop loss or RTT above threshold → **yellow** (ISP access degraded)
- Both internet references bad → **yellow** (upstream degraded beyond your ISP)
- One reference bad → **yellow** (path to that reference degraded — not your network)
- Otherwise → **green**

## Install

1. Install [SwiftBar](https://swiftbar.app/) if you have not already.
2. Copy the plugin into SwiftBar's plugin directory:

```sh
mkdir -p ~/Library/Application\ Support/SwiftBar/plugins
curl -o ~/Library/Application\ Support/SwiftBar/plugins/network-health.30s.sh \
  https://raw.githubusercontent.com/dangayle/network-health-swiftbar/main/network-health.30s.sh
chmod +x ~/Library/Application\ Support/SwiftBar/plugins/network-health.30s.sh
```

3. SwiftBar picks it up automatically; the `.30s.sh` suffix means it refreshes every 30 seconds.

macOS only — it uses `route -n get default`, `ping`, `traceroute`, and `networkQuality`.

## Tune it

Thresholds are configurable via environment variables (set them in SwiftBar's plugin environment or in the script):

| Variable | Default | Meaning |
| --- | --- | --- |
| `GW_MAX_MS` | `30` | Router avg RTT above this → local link degraded |
| `ISP_MAX_MS` | `60` | ISP first hop avg RTT above this → ISP degraded |
| `REF_MAX_MS` | `100` | Internet reference avg RTT above this → upstream degraded |
| `LOSS_MAX` | `2` | Packet loss % above this at any layer → degraded |
| `GW_COUNT` | `4` | Ping count for the router probe |
| `REF_COUNT` | `3` | Ping count for each internet reference |
| `ISP_PROBES` | `3` | Traceroute probes to the ISP hop |

## Selftest

The script ships with a built-in test suite that covers the output parsers and every classification branch:

```sh
./network-health.30s.sh selftest
```

## Known limits

- Probes are ICMP-only. Some routers deprioritize ICMP, which can produce false "degraded" verdicts on otherwise fine links. A TCP-handshake RTT cross-check is the upgrade path if you see that.
- Fixed thresholds, not learned baselines. If your thresholds flap, tune the env vars above.

## License

MIT
