#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKDIR="$ROOT_DIR/workers/tongyi"
CONFIG_FILE="$WORKDIR/wrangler.toml"

ALLOWED_LAG_SECONDS="${TONGYI_HEARTBEAT_ALLOWED_LAG_SECONDS:-300}"
REPAIR_CRON="${TONGYI_REPAIR_CRON:-*/2 * * * *}"
WAIT_SECONDS="${TONGYI_REPAIR_WAIT_SECONDS:-420}"
POLL_SECONDS="${TONGYI_REPAIR_POLL_SECONDS:-30}"
FORCE_REPAIR="${FORCE_REPAIR:-0}"

if [[ -z "${CF_API_TOKEN_TONGYI:-}" ]]; then
  echo "Missing CF_API_TOKEN_TONGYI. Export the old-account token first." >&2
  exit 1
fi

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Missing $CONFIG_FILE" >&2
  exit 1
fi

ACCOUNT_ID="$(awk -F '"' '/^account_id = / { print $2; exit }' "$CONFIG_FILE")"
KV_NAMESPACE_ID="$(awk -F '"' '/^id = / { print $2; exit }' "$CONFIG_FILE")"

if [[ -z "$ACCOUNT_ID" || -z "$KV_NAMESPACE_ID" ]]; then
  echo "Failed to read account_id or KV namespace id from $CONFIG_FILE" >&2
  exit 1
fi

kv_value() {
  local key="$1"
  curl -fsS \
    -H "Authorization: Bearer $CF_API_TOKEN_TONGYI" \
    "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/storage/kv/namespaces/$KV_NAMESPACE_ID/values/$key"
}

now_ms() {
  node -e 'process.stdout.write(String(Date.now()))'
}

format_ms() {
  node -e 'const ts=Number(process.argv[1]); if (!Number.isFinite(ts) || ts <= 0) process.exit(1); console.log(new Date(ts + 8 * 3600e3).toISOString().replace("T", " ").slice(0, 19) + " Beijing");' "$1"
}

last_expected_cron_ms() {
  node - "$CONFIG_FILE" <<'NODE'
const fs = require("fs");
const configPath = process.argv[2];
const text = fs.readFileSync(configPath, "utf8");
const match = text.match(/crons\s*=\s*\[([^\]]*)\]/);
if (!match) process.exit(0);

const crons = [...match[1].matchAll(/"([^"]+)"/g)].map(item => item[1]);

function expandField(field, min, max) {
  const values = new Set();
  for (const rawPart of String(field || "").split(",")) {
    const part = rawPart.trim();
    if (!part) continue;

    let range = part;
    let step = 1;
    if (part.includes("/")) {
      const pieces = part.split("/");
      range = pieces[0];
      step = Number(pieces[1]);
      if (!Number.isInteger(step) || step <= 0) throw new Error(`bad cron step: ${part}`);
    }

    let start;
    let end;
    if (range === "*") {
      start = min;
      end = max;
    } else if (range.includes("-")) {
      const pieces = range.split("-").map(Number);
      start = pieces[0];
      end = pieces[1];
    } else {
      start = Number(range);
      end = Number(range);
    }

    if (!Number.isInteger(start) || !Number.isInteger(end) || start < min || end > max || start > end) {
      throw new Error(`bad cron field: ${field}`);
    }
    for (let value = start; value <= end; value += step) values.add(value);
  }
  return values;
}

const schedules = crons.map(line => {
  const parts = line.trim().split(/\s+/);
  if (parts.length !== 5) return null;
  return {
    line,
    minutes: expandField(parts[0], 0, 59),
    hours: expandField(parts[1], 0, 23),
  };
}).filter(Boolean);

const now = Date.now();
const startMinute = Math.floor(now / 60000) * 60000;
let best = null;

for (let offset = 0; offset <= 48 * 60; offset += 1) {
  const ts = startMinute - offset * 60000;
  const d = new Date(ts);
  const minute = d.getUTCMinutes();
  const hour = d.getUTCHours();
  const hit = schedules.find(schedule => schedule.minutes.has(minute) && schedule.hours.has(hour));
  if (hit) {
    best = { ts, line: hit.line };
    break;
  }
}

if (best) {
  process.stdout.write(JSON.stringify(best));
}
NODE
}

deploy_config() {
  local config="$1"
  (
    cd "$WORKDIR"
    CLOUDFLARE_API_TOKEN="$CF_API_TOKEN_TONGYI" npx wrangler deploy --config "$config"
  )
}

last_ts="$(kv_value "meta%3Aheartbeat%3Alast_ts" 2>/dev/null || true)"
last_minute="$(kv_value "meta%3Aheartbeat%3Alast_minute" 2>/dev/null || true)"
current_ms="$(now_ms)"

expected_json="$(last_expected_cron_ms)"
expected_ts="$(node -e 'const raw=process.argv[1]; if (!raw) process.exit(0); process.stdout.write(String(JSON.parse(raw).ts));' "$expected_json")"
expected_line="$(node -e 'const raw=process.argv[1]; if (!raw) process.exit(0); process.stdout.write(JSON.parse(raw).line);' "$expected_json")"

echo "[repair_tongyi_cron] heartbeat last_ts=${last_ts:-missing} last_minute=${last_minute:-missing}"
if [[ "$expected_ts" =~ ^[0-9]+$ ]]; then
  echo "[repair_tongyi_cron] last expected cron=${expected_line} at $(format_ms "$expected_ts")"
fi

if [[ "$FORCE_REPAIR" != "1" ]]; then
  if [[ ! "$expected_ts" =~ ^[0-9]+$ ]]; then
    echo "[repair_tongyi_cron] no recent expected cron found; skip repair. Use FORCE_REPAIR=1 to force."
    exit 0
  fi
  if [[ "$last_ts" =~ ^[0-9]+$ && "$last_ts" -ge $(( expected_ts - ALLOWED_LAG_SECONDS * 1000 )) ]]; then
    echo "[repair_tongyi_cron] heartbeat already covers the latest expected cron; skip repair. Use FORCE_REPAIR=1 to force."
    exit 0
  fi
fi

tmp_config="$(mktemp "$WORKDIR/wrangler.repair.XXXXXX.toml")"
trap 'rm -f "$tmp_config"' EXIT

cp "$CONFIG_FILE" "$tmp_config"
export REPAIR_CRON
LC_ALL=C perl -0pi -e '
  my $repair = $ENV{"REPAIR_CRON"};
  s{crons = \[([^\]]*)\]}{
    my $inside = $1;
    if (index($inside, $repair) >= 0) {
      "crons = [$inside]";
    } elsif ($inside =~ /\S/) {
      "crons = [$inside, \"$repair\"]";
    } else {
      "crons = [\"$repair\"]";
    }
  }e;
' "$tmp_config"

before_ts="$last_ts"
echo "[repair_tongyi_cron] deploy temporary cron: $REPAIR_CRON"
deploy_config "$tmp_config"

deadline=$(( $(date +%s) + WAIT_SECONDS ))
recovered=0

while [[ "$(date +%s)" -lt "$deadline" ]]; do
  sleep "$POLL_SECONDS"
  current_ts="$(kv_value "meta%3Aheartbeat%3Alast_ts" 2>/dev/null || true)"
  current_minute="$(kv_value "meta%3Aheartbeat%3Alast_minute" 2>/dev/null || true)"
  echo "[repair_tongyi_cron] poll heartbeat last_ts=${current_ts:-missing} last_minute=${current_minute:-missing}"
  if [[ "$current_ts" =~ ^[0-9]+$ && ( ! "$before_ts" =~ ^[0-9]+$ || "$current_ts" -gt "$before_ts" ) ]]; then
    recovered=1
    break
  fi
done

echo "[repair_tongyi_cron] restore normal cron config"
deploy_config "$CONFIG_FILE"

if [[ "$recovered" == "1" ]]; then
  echo "[repair_tongyi_cron] recovered at $(format_ms "$current_ts")"
  exit 0
fi

echo "[repair_tongyi_cron] heartbeat did not advance within ${WAIT_SECONDS}s; restored normal config anyway." >&2
exit 2
