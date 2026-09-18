#!/usr/bin/env bash
# model-features.sh — 28-check regression on the remote_opencode_sync model
# helpers (model_from_global / model_get / model_resolve / model_set in
# scripts/lib.sh) plus the 'roe model' front-end subcommand.
#
# Run:  tests/model-features.sh
# Env:  ROE_REPO=<repo root> (default: this repo); ROE_SANDBOX_ROOT=<scratch dir>
#       (default: /tmp/opencode/modeltest).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROE="${ROE_REPO:-$(dirname "$SCRIPT_DIR")}"
ROOT="${ROE_SANDBOX_ROOT:-/tmp/opencode/modeltest}"
MHOME="$ROOT/global"          # HOME variant with a global opencode config
EHOME="$ROOT/empty-home"      # HOME variant with no global config at all

OK=0; FAIL=0
t() { OK=$((OK+1)); }
f() { FAIL=$((FAIL+1)); echo "FAIL: $*" >&2; }
check() { local name="$1" got="$2" detail="${3:-}"; if [[ "$got" == "0" ]]; then t; echo "  ok ${OK}  $name"; else f "$name ($detail)"; fi; }

rm -rf "${ROOT:?}" && mkdir -p "$ROOT" "$MHOME/.config/opencode" "$EHOME"
printf '{\n  "model": "opencode/global-model"\n}\n' > "$MHOME/.config/opencode/opencode.json"

source "$ROE/scripts/lib.sh"

# --- A. model_from_global (4) ---
( export HOME="$EHOME"; [[ -z "$(model_from_global)" ]]; echo $? )
check "from_global: empty when no global config" "$?" ""
( export HOME="$MHOME"; printf '{}\n' > "$HOME/.config/opencode/opencode.json"; [[ -z "$(model_from_global)" ]]; echo $? )
check "from_global: empty when config lacks a model" "$?" ""
( export HOME="$MHOME"; printf '{\n  "model": "opencode/global-model"\n}\n' > "$HOME/.config/opencode/opencode.json"; [[ "$(model_from_global)" == "opencode/global-model" ]]; echo $? )
check "from_global: extracts the model id" "$?" ""
( export HOME="$MHOME"; printf '{\n  "model"   :   "opencode/spaced"\n}\n' > "$HOME/.config/opencode/opencode.json"; [[ "$(model_from_global)" == "opencode/spaced" ]]; echo $? )
check "from_global: tolerant of spaces/tabs around key" "$?" ""

# --- B. model_get (7) ---
check "get: empty dir has no model" "$( ! model_get "$ROOT/get-no-config" 2>/dev/null; echo $?)" "exit=$?"
mkdir -p "$ROOT/get/no-model"
printf '{}\n' > "$ROOT/get/no-model/opencode.jsonc"
check "get: config without model key -> none" "$( ! model_get "$ROOT/get/no-model"; echo $?)" ""
mkdir -p "$ROOT/get/jsonc"
printf '{\n  "model": "opencode/from-jsonc"\n}\n' > "$ROOT/get/jsonc/opencode.jsonc"
check "get: reads model from opencode.jsonc" "$([[ "$(model_get "$ROOT/get/jsonc")" == "opencode/from-jsonc" ]]; echo $?)" ""
mkdir -p "$ROOT/get/json-only"
printf '{\n  "model": "opencode/from-json"\n}\n' > "$ROOT/get/json-only/opencode.json"
check "get: reads model from opencode.json" "$([[ "$(model_get "$ROOT/get/json-only")" == "opencode/from-json" ]]; echo $?)" ""
mkdir -p "$ROOT/get/precedence"
printf '{\n  "model": "opencode/winner"\n}\n' > "$ROOT/get/precedence/opencode.json"
printf '{\n  "model": "opencode/loser"\n}\n' > "$ROOT/get/precedence/opencode.jsonc"
check "get: opencode.json wins over opencode.jsonc" "$([[ "$(model_get "$ROOT/get/precedence")" == "opencode/winner" ]]; echo $?)" ""
mkdir -p "$ROOT/get/fallback"
printf '{}\n' > "$ROOT/get/fallback/opencode.json"
printf '{\n  "model": "opencode/fallback-jsonc"\n}\n' > "$ROOT/get/fallback/opencode.jsonc"
check "get: falls back to jsonc when json lacks a model" "$([[ "$(model_get "$ROOT/get/fallback")" == "opencode/fallback-jsonc" ]]; echo $?)" ""
mkdir -p "$ROOT/get/notstring"
printf '{\n  "model": 456\n}\n' > "$ROOT/get/notstring/opencode.json"
check "get: ignores non-string model value" "$( ! model_get "$ROOT/get/notstring"; echo $?)" ""

# --- C. model_resolve (6) ---
( export HOME="$MHOME"; printf '{\n  "model": "opencode/global-model"\n}\n' > "$HOME/.config/opencode/opencode.json"; [[ "$(MODEL_PIN=opencode/pin model_resolve opencode/req)" == "opencode/req" ]]; echo $? )
check "resolve: explicit requested wins over PIN + global" "$?" ""
( export HOME="$MHOME"; printf '{\n  "model": "opencode/global-model"\n}\n' > "$HOME/.config/opencode/opencode.json"; [[ "$(MODEL_PIN=opencode/pin model_resolve)" == "opencode/pin" ]]; echo $? )
check "resolve: MODEL_PIN beats the global config model" "$?" ""
( export HOME="$MHOME"; printf '{\n  "model": "opencode/global-model"\n}\n' > "$HOME/.config/opencode/opencode.json"; [[ "$(MODEL_PIN= model_resolve)" == "opencode/global-model" ]]; echo $? )
check "resolve: global config used when no requested/PIN" "$?" ""
( export HOME="$EHOME"; MODEL_PIN=; ! model_resolve </dev/null >/dev/null 2>&1; echo $? )
check "resolve: empty when nothing available and prompt declined" "$?" ""
check "resolve: interactive prompt returns typed id" "$([[ "$(printf 'opencode/typed\n' | MODEL_PIN= model_resolve)" == "opencode/typed" ]]; echo $?)" ""
( export HOME="$EHOME"; MODEL_PIN=opencode/pin; [[ "$(printf 'opencode/typed\n' | model_resolve)" == "opencode/pin" ]]; echo $? )
check "resolve: never prompts when a PIN is available" "$?" ""

# --- D. model_set (7) ---
mkdir -p "$ROOT/set/fresh"
out="$(model_set "$ROOT/set/fresh" "opencode/brand-new")"
python3 - "$out" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d["model"]=="opencode/brand-new" and "$schema" in d, d
PY
v="$?"
check "set: creates one valid minimal opencode.jsonc in empty dir" "$([[ "$out" == "$ROOT/set/fresh/opencode.jsonc" ]] && [[ "$v" == "0" ]]; echo $?)" "$out"
mkdir -p "$ROOT/set/rewrite"
printf '{\n  "$schema": "https://opencode.ai/config.json",\n  "model": "opencode/old",\n  "keep": "yes"\n}\n' > "$ROOT/set/rewrite/opencode.jsonc"
model_set "$ROOT/set/rewrite" "opencode/new" >/dev/null
check "set: rewrites model in place, sibling keys kept" "$([[ "$(model_get "$ROOT/set/rewrite")" == "opencode/new" ]] && grep -q '"keep": "yes"' "$ROOT/set/rewrite/opencode.jsonc"; echo $?)" ""
mkdir -p "$ROOT/set/both"
printf '{\n  "model": "opencode/json-old"\n}\n' > "$ROOT/set/both/opencode.json"
printf '{\n  "model": "opencode/jsonc-old"\n}\n' > "$ROOT/set/both/opencode.jsonc"
model_set "$ROOT/set/both" "opencode/reboth" >/dev/null
check "set: prefers opencode.json, leaves jsonc alone" "$([[ "$(model_get "$ROOT/set/both")" == "opencode/reboth" ]] && grep -q 'opencode/jsonc-old' "$ROOT/set/both/opencode.jsonc"; echo $?)" ""
mkdir -p "$ROOT/set/inject"
printf '{\n  "$schema": "https://opencode.ai/config.json",\n  "something": "kept"\n}\n' > "$ROOT/set/inject/opencode.jsonc"
model_set "$ROOT/set/inject" "opencode/injected" >/dev/null
check "set: injects missing key and keeps other keys" "$(grep -q '"something": "kept"' "$ROOT/set/inject/opencode.jsonc" && [[ "$(model_get "$ROOT/set/inject")" == "opencode/injected" ]]; echo $?)" ""
python3 - "$ROOT/set/inject/opencode.jsonc" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d["model"]=="opencode/injected" and d["something"]=="kept", d
PY
check "set: injected config is valid JSON" "$?" ""
mkdir -p "$ROOT/set/trailing"
printf '{\n  "a": 1,\n}\n' > "$ROOT/set/trailing/opencode.jsonc"
model_set "$ROOT/set/trailing" "opencode/trail" >/dev/null
python3 - "$ROOT/set/trailing/opencode.jsonc" <<'PY'
import json,sys
d=json.load(open(sys.argv[1]))
assert d["model"]=="opencode/trail" and d["a"]==1, d
PY
check "set: injection correct with trailing comma" "$?" ""
mkdir -p "$ROOT/set/jsonc-inject"
printf '{ // start\n  "a": 1 // no trailing comma\n}\n' > "$ROOT/set/jsonc-inject/opencode.jsonc"
model_set "$ROOT/set/jsonc-inject" "opencode/trail" >/dev/null
python3 - "$ROOT/set/jsonc-inject/opencode.jsonc" <<'PY'
import json,sys,re
s=open(sys.argv[1]).read()
s=re.sub(r'//[^\n]*','',s)
s=re.sub(r',\s*}','}',s)
d=json.loads(s)
assert d["model"]=="opencode/trail" and d["a"]==1, d
PY
v2="$?"
check "set: valid JSONC with comments + round-trips" "$([[ "$v2" == "0" ]] && [[ "$(model_get "$ROOT/set/jsonc-inject")" == "opencode/trail" ]]; echo $?)" ""

# --- E. bin/roe model subcommand (4) ---
mkdir -p "$ROOT/roe"
( cd "$ROOT/roe" && bash "$ROE/bin/roe" model > roe-nopin.out 2>&1 )
check "roe model: reports when nothing pinned" "$(grep -q 'no model pinned' "$ROOT/roe/roe-nopin.out"; echo $?)" "$(cat "$ROOT/roe/roe-nopin.out")"
( cd "$ROOT/roe" && bash "$ROE/bin/roe" model opencode/big-pickle > roe-pin.out 2>&1 )
check "roe model <id>: pins and reports the file" "$(grep -q "pinned model 'opencode/big-pickle' in opencode.jsonc" "$ROOT/roe/roe-pin.out"; echo $?)" "$(cat "$ROOT/roe/roe-pin.out")"
( cd "$ROOT/roe" && bash "$ROE/bin/roe" model > roe-show.out 2>&1 )
check "roe model: now shows the pinned model" "$(grep -q 'opencode/big-pickle' "$ROOT/roe/roe-show.out"; echo $?)" "$(cat "$ROOT/roe/roe-show.out")"
( cd "$ROOT/roe" && bash "$ROE/bin/roe" model a b > roe-toomany.out 2>&1 ); rc=$?
check "roe model: too many args exits 2" "$([[ "$rc" == "2" ]]; echo $?)" "exit=$rc"

echo "model-features.sh: $OK checks, $FAIL failed"
exit "$FAIL"