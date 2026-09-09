#!/bin/bash
# network-health — SwiftBar plugin. Flags when your local network is the problem.
#
# Install:
#   mkdir -p ~/Library/Application\ Support/SwiftBar/plugins
#   cp network-health.30s.sh ~/Library/Application\ Support/SwiftBar/plugins/
#
# Menu bar: "● 8ms" = RTT to your router.
#   green  = local + ISP + internet healthy — trust what you see in the browser
#   yellow = ISP hop OR upstream degraded — site may look slow, not the site's fault
#   red    = local Wi-Fi link degraded — retest before blaming the site
#   gray   = no data
#
# Layers measured (each adds one segment of the path):
#   1. Router        — your Wi-Fi + local LAN only (ICMP ping)
#   2. ISP first hop — first Xfinity node past your router.
#                      Measured with traceroute TTL-exceeded probes, because
#                      Xfinity's CGNAT hop ignores ICMP echo (observed 2026-09).
#   3. Internet refs — Cloudflare 1.1.1.1 + Google 8.8.8.8, through Xfinity (ICMP ping)
#
# Tune thresholds with env vars (GW_MAX_MS, ISP_MAX_MS, REF_MAX_MS, LOSS_MAX).
#
# ponytail: fixed thresholds, ICMP-only probes. ICMP can be deprioritized by
# routers; if you see false "degraded" verdicts, add a TCP-handshake RTT
# cross-check before trusting it. Learned per-BSSID baselines are the upgrade
# path if fixed thresholds flap.

GW_MAX_MS=${GW_MAX_MS:-30}    # router avg RTT above this = local link degraded
ISP_MAX_MS=${ISP_MAX_MS:-60}  # ISP first hop avg RTT above this = Xfinity degraded
REF_MAX_MS=${REF_MAX_MS:-100} # internet reference avg RTT above this = upstream degraded
LOSS_MAX=${LOSS_MAX:-2}       # loss % above this at any layer = degraded
GW_COUNT=${GW_COUNT:-4}
REF_COUNT=${REF_COUNT:-3}
ISP_PROBES=${ISP_PROBES:-3}   # traceroute probes to the ISP hop
REFS=(1.1.1.1 8.8.8.8)

# --- parsers: stdin = command output, stdout = number (empty if absent) ---
loss_pct() { # `ping -q`
  awk '{for(i=1;i<=NF;i++) if($i ~ /^[0-9.]+%/) {print substr($i,1,length($i)-1); exit}}'
}
avg_ms() { # `ping -q`
  awk -F= '/round-trip/{n=split($2,a,"/"); if(n>=2){gsub(/[^0-9.]/,"",a[2]); print a[2]; exit}}'
}
isp_parse() { # `traceroute -n -m 2` -> "ip loss avg" (loss = % probes unanswered)
  awk '$1==2 {
    ip=($2 ~ /^[0-9.]+$/) ? $2 : ""
    n=0; sum=0; miss=0
    for (i=3;i<=NF;i++) {
      if ($i ~ /^[0-9.]+$/ && $(i+1)=="ms") {n++; sum+=$i}
      else if ($i=="*") miss++
    }
    if (n==0) {print "unknown 100 -1"; exit}
    printf "%s %.1f %.3f\n", ip, miss/(n+miss)*100, sum/n; exit
  }'
}
gt() { # gt A B -> 1 if A > B else 0 (awk float compare, bc-free)
  awk "BEGIN{print ($1>$2)?1:0}"
}

# classify <gw_loss> <gw_avg> <isp_loss> <isp_avg> <r1_loss> <r1_avg> <r2_loss> <r2_avg>
# prints "color<TAB>reason"
classify() {
  local gl=$1 ga=$2 il=$3 ia=$4 l1=$5 a1=$6 l2=$7 a2=$8
  if [[ $gl == -1 && $ga == -1 ]]; then
    printf 'gray\tNo router data'; return
  fi
  if [[ $(gt "$gl" "$LOSS_MAX") == 1 || $(gt "$ga" "$GW_MAX_MS") == 1 ]]; then
    printf 'red\tLocal Wi-Fi degraded (router %sms, %s%% loss)' "$ga" "$gl"; return
  fi
  # ISP tier only usable when the hop answers traceroute probes
  if [[ $ia != -1 ]] && { [[ $(gt "$il" "$LOSS_MAX") == 1 || $(gt "$ia" "$ISP_MAX_MS") == 1 ]]; }; then
    printf 'yellow\tISP access degraded — Xfinity first hop %sms, %s%% probes unanswered' "$ia" "$il"; return
  fi
  local bad1=0 bad2=0
  [[ $(gt "$l1" "$LOSS_MAX") == 1 || $a1 == -1 || $(gt "$a1" "$REF_MAX_MS") == 1 ]] && bad1=1
  [[ $(gt "$l2" "$LOSS_MAX") == 1 || $a2 == -1 || $(gt "$a2" "$REF_MAX_MS") == 1 ]] && bad2=1
  if (( bad1 && bad2 )); then
    printf 'yellow\tUpstream degraded beyond ISP hop (both references bad)'; return
  fi
  if (( bad1 )); then printf 'yellow\tPath to %s degraded (%sms, %s%% loss) — not your network' "${REFS[0]}" "$a1" "$l1"; return; fi
  if (( bad2 )); then printf 'yellow\tPath to %s degraded (%sms, %s%% loss) — not your network' "${REFS[1]}" "$a2" "$l2"; return; fi
  printf 'green\tAll layers healthy — router %sms, slow page = the site' "$ga"
}

selftest() {
  local fails=0
  assert() { [[ "$2" == "$3" ]] || { echo "FAIL $1: expected '$3' got '$2'"; fails=$((fails+1)); }; }
  assert "loss parse" "$(printf '4 packets transmitted, 4 packets received, 12.5%% packet loss\n' | loss_pct)" "12.5"
  assert "loss parse 100" "$(printf '4 packets transmitted, 0 packets received, 100.0%% packet loss\n' | loss_pct)" "100.0"
  assert "avg parse" "$(printf 'round-trip min/avg/max/stddev = 8.3/9.1/10.7/0.9 ms\n' | avg_ms)" "9.1"
  assert "avg missing" "$(printf 'no rtt line\n' | avg_ms)" ""
  assert "isp parse ok" "$(printf ' 2  100.92.122.106  12.345 ms  13.100 ms  11.900 ms\n' | isp_parse)" "100.92.122.106 0.0 12.448"
  assert "isp parse miss" "$(printf ' 2  1.2.3.4  10.0 ms  *  12.0 ms\n' | isp_parse)" "1.2.3.4 33.3 11.000"
  assert "isp parse dead" "$(printf ' 2  * * *\n' | isp_parse)" "unknown 100 -1"
  assert "green"        "$(classify 0 8 0 15 0 15 0 14 | cut -f1)" "green"
  assert "red rtt"      "$(classify 0 45 -1 -1 0 15 0 14 | cut -f1)" "red"
  assert "red loss"     "$(classify 5 9 -1 -1 0 15 0 14 | cut -f1)" "red"
  assert "red gw down"  "$(classify 100 -1 -1 -1 0 15 0 14 | cut -f1)" "red"
  assert "yellow isp rtt"  "$(classify 0 8 0 80 0 15 0 14 | cut -f1)" "yellow"
  assert "yellow isp loss" "$(classify 0 8 5 20 0 15 0 14 | cut -f1)" "yellow"
  assert "isp no data skipped" "$(classify 0 8 -1 -1 0 150 0 160 | cut -f1)" "yellow"
  assert "yellow both"  "$(classify 0 8 0 15 0 150 0 160 | cut -f1)" "yellow"
  assert "yellow one"   "$(classify 0 8 0 15 0 15 0 200 | cut -f1)" "yellow"
  assert "yellow loss"  "$(classify 0 8 0 15 3 15 0 14 | cut -f1)" "yellow"
  assert "gray"         "$(classify -1 -1 -1 -1 0 15 0 14 | cut -f1)" "gray"
  [[ $(classify 0 8 0 80 0 15 0 14 | cut -f2) == *"Xfinity"* ]] || { echo "FAIL isp reason text"; fails=$((fails+1)); }
  echo "selftest: $fails failure(s)"
  (( fails == 0 ))
}

[[ "${1:-}" == "selftest" ]] && selftest && exit $? || [[ "${1:-}" == "selftest" ]] && exit 1

# --- run all probes in parallel ---
GW=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2; exit}')
if [[ -z "$GW" ]]; then
  echo "● — | color=gray tooltip=No default route"
  echo ---
  echo "No default route found"
  exit 0
fi

tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
pids=()
ping -q -c "$GW_COUNT" -t 6 "$GW" > "$tmp/gw" 2>/dev/null & pids+=($!)
traceroute -n -w 2 -q "$ISP_PROBES" -m 2 "${REFS[0]}" > "$tmp/isp" 2>/dev/null & pids+=($!)
ping -q -c "$REF_COUNT" -t 6 "${REFS[0]}" > "$tmp/ref0" 2>/dev/null & pids+=($!)
ping -q -c "$REF_COUNT" -t 6 "${REFS[1]}" > "$tmp/ref1" 2>/dev/null & pids+=($!)
wait "${pids[@]}" 2>/dev/null

gl=$(loss_pct < "$tmp/gw");  ga=$(avg_ms < "$tmp/gw");  gl=${gl:--1}; ga=${ga:--1}
read -r isp_ip il ia <<< "$(isp_parse < "$tmp/isp")"; il=${il:--1}; ia=${ia:--1}
l1=$(loss_pct < "$tmp/ref0"); a1=$(avg_ms < "$tmp/ref0"); l1=${l1:--1}; a1=${a1:--1}
l2=$(loss_pct < "$tmp/ref1"); a2=$(avg_ms < "$tmp/ref1"); l2=${l2:--1}; a2=${a2:--1}

verdict=$(classify "$gl" "$ga" "$il" "$ia" "$l1" "$a1" "$l2" "$a2")
color=${verdict%%$'\t'*}
reason=${verdict#*$'\t'}
rtt_display=$([[ $ga == -1 ]] && echo "—" || echo "${ga}ms")

# --- SwiftBar output ---
echo "● $rtt_display | color=$color tooltip=$reason"
echo ---
echo "Layers: 1 Router = your Wi-Fi · 2 ISP hop = Xfinity · 3 Refs = open internet"
echo ---
detail() { # label loss avg max_ms
  local c=green
  [[ $(gt "$2" "$LOSS_MAX") == 1 || $3 == -1 ]] && c=red
  [[ $c == green && $(gt "$3" "$4") == 1 ]] && c=yellow
  echo "$1: ${3}ms, ${2}% loss | color=$c"
}
detail "Layer 1 — Wi-Fi to router ($GW)" "$gl" "$ga" "$GW_MAX_MS"
if [[ $ia != -1 ]]; then
  detail "Layer 2 — Xfinity first hop ($isp_ip)" "$il" "$ia" "$ISP_MAX_MS"
else
  echo "Layer 2 — Xfinity first hop: no response to probes | color=gray"
fi
detail "Layer 3 — Internet via Cloudflare (${REFS[0]})" "$l1" "$a1" "$REF_MAX_MS"
detail "Layer 3 — Internet via Google (${REFS[1]})" "$l2" "$a2" "$REF_MAX_MS"
echo ---
echo "Verdict: $reason | color=$color"
echo ---
echo "Run networkQuality test (saturates connection — close other test tabs) | shell=/usr/bin/networkQuality param1=-c terminal=true refresh=true"
echo "Refresh now | refresh=true"
