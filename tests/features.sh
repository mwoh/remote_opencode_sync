#!/usr/bin/env bash
# features.sh — sandboxed end-to-end checks for remote_opencode_sync
# (resumable new/adopt, roe desync/resync, roe projects/clone, model pinning).
# Uses a fake gh (tests/shims/gh) backed by bare repos under $GH_FAKE_ROOT, with
# origin URLs pointed at them via GITHUB_SSH_BASE.
#
# Run:  tests/features.sh
# Env:  ROE_REPO=<repo root> (default: this repo); ROE_SANDBOX_ROOT=<scratch dir>
#       (default: /tmp/opencode/roetest).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROE="${ROE_REPO:-$(dirname "$SCRIPT_DIR")}"
SHIMS="$SCRIPT_DIR/shims"
ROOT="${ROE_SANDBOX_ROOT:-/tmp/opencode/roetest}"
export GH_FAKE_ROOT="$ROOT/ghroot"
export GH_FAKE_AUTH=yes
export GH_FAKE_OWNER=fakeuser
export GITHUB_SSH_BASE="file://$GH_FAKE_ROOT/"
export GITHUB_USER=fakeuser
export PATH="$SHIMS:$PATH"
export HOME="$ROOT/home-fake"

OK=0; FAIL=0
t() { OK=$((OK+1)); }
f() { FAIL=$((FAIL+1)); echo "FAIL: $*" >&2; }
check() { local name="$1" got="$2" detail="${3:-}"; if [[ "$got" == "0" ]]; then t; echo "  ok ${OK}  $name"; else f "$name ($detail)"; fi; }
expect_exit() { local name="$1" want="$2" got="$3" detail="${4:-}"; if [[ "$want" == "$got" ]]; then t; echo "  ok ${OK}  $name"; else f "$name (exit $got != $want; $detail)"; fi; }

ssh_url() { printf 'file://%s/%s/%s.git' "$GH_FAKE_ROOT" "$GH_FAKE_OWNER" "$1"; }
# mkbare <name> — bare repo whose HEAD points at main (like a fresh GitHub repo).
mkbare() { git init --bare -q "$GH_FAKE_ROOT/$GH_FAKE_OWNER/$1.git"; git --git-dir "$GH_FAKE_ROOT/$GH_FAKE_OWNER/$1.git" symbolic-ref HEAD refs/heads/main; }
# remote_head <name> — last commit reachable from the bare's HEAD.
remote_head() { git --git-dir "$GH_FAKE_ROOT/$GH_FAKE_OWNER/$1.git" log --oneline -1 2>/dev/null; }
seed_remote() { local bare="$1"; (cd "$(mktemp -d)" && git init -q -b main . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m c && git push -q "$bare" main); }

rm -rf "${ROOT:?}"/* && mkdir -p "$ROOT/home-fake" "$GH_FAKE_ROOT/fakeuser"
git config --global user.name "Fake T"
git config --global user.email "t@f.test"

source "$ROE/scripts/lib.sh"

echo "== model helper regression =="
mkdir -p "$ROOT/m/dir"
printf '{\n  "$schema": "https://opencode.ai/config.json"\n}\n' > "$ROOT/m/dir/opencode.jsonc"
out="$(model_set "$ROOT/m/dir" "opencode/big-pickle")"
check "model_set echos the file" "$([[ "$out" == "$ROOT/m/dir/opencode.jsonc" ]]; echo $?)" "$out"
check "model key present" "$([[ "$(model_get "$ROOT/m/dir")" == "opencode/big-pickle" ]]; echo $?)" ""
python3 - "$ROOT/m/dir/opencode.jsonc" <<'PY'
import json,sys,re
s=open(sys.argv[1]).read()
s=re.sub(r'(?m)^\s*//.*$','',s)
s=re.sub(r',\s*}','}',s)
json.loads(s)
PY
check "injected jsonc is valid" "$?" ""

echo "== A. fresh create with pinned model =="
mkdir -p "$ROOT/A" && cd "$ROOT/A"
"$ROE/scripts/new-project.sh" alpha --model opencode/big-pickle > "$ROOT/A/create.out" 2>&1
expect_exit "new alpha exits 0" 0 $? "$(tail -n2 "$ROOT/A/create.out")"
local_head="$(git -C alpha log --oneline -1)"
check "seeded marker present" "$([[ "$(cat alpha/.opencode/toolkit)" == "remote_opencode_sync" ]]; echo $?)" ""
check "model pinned in opencode.jsonc" "$(grep -q '"model": "opencode/big-pickle"' alpha/opencode.jsonc; echo $?)" ""
check "seeded opencode.jsonc has the commands" "$(test "$(grep -c '"template"' alpha/opencode.jsonc)" -ge 3; echo $?)" ""
check "committed and pushed" "$([[ "$local_head" == "$(remote_head alpha)" ]]; echo $?)" "local=$local_head remote=$(remote_head alpha)"
check "origin normalized to target" "$([[ "$(git -C alpha remote get-url origin)" == "$(ssh_url alpha)" ]]; echo $?)" "$(git -C alpha remote get-url origin)"
check "local branch is main" "$([[ "$(git -C alpha rev-parse --abbrev-ref HEAD)" == "main" ]]; echo $?)" ""
check "pushed ref is main" "$(git --git-dir "$GH_FAKE_ROOT/fakeuser/alpha.git" show-ref --verify --quiet refs/heads/main; echo $?)" ""

echo "== B. resume: committed but push-now-fails =="
mkdir -p "$ROOT/B"
cp -r "$ROOT/A/alpha" "$ROOT/B/alpha"
rm -rf "$GH_FAKE_ROOT/fakeuser/alpha.git"
( cd "$ROOT/B" && "$ROE/scripts/new-project.sh" alpha > "$ROOT/B/resume1.out" 2>&1 )
expect_exit "resume detects previous clone + push fails" 1 $? "$(tail -n2 "$ROOT/B/resume1.out")"
check "push failure tells you to re-run" "$(grep -q 'Re-run the same command to resume' "$ROOT/B/resume1.out"; echo $?)" ""
check "no duplicate scaffold commit on failed resume" "$(test "$(git -C "$ROOT/B/alpha" log --oneline | wc -l)" -le 1; echo $?)" "commits: $(git -C "$ROOT/B/alpha" log --oneline | wc -l)"
mkbare alpha
( cd "$ROOT/B" && "$ROE/scripts/new-project.sh" alpha > "$ROOT/B/resume2.out" 2>&1 )
expect_exit "resume then succeeds after remote returns" 0 $? "$(tail -n2 "$ROOT/B/resume2.out")"
local2="$(git -C "$ROOT/B/alpha" log --oneline -1)"
check "final state pushed" "$([[ "$local2" == "$(remote_head alpha)" ]]; echo $?)" "local=$local2 remote=$(remote_head alpha)"
check "resume did not ask for a model" "$(! grep -q 'Model id' "$ROOT/B/resume2.out"; echo $?)" ""

echo "== C. resume: empty stub, no local dir =="
mkdir -p "$ROOT/C"
mkbare charlie
( cd "$ROOT/C" && "$ROE/scripts/new-project.sh" charlie --model opencode/big-pickle > "$ROOT/C/stub.out" 2>&1 )
expect_exit "empty stub cloned+seeded+pushed" 0 $? "$(tail -n2 "$ROOT/C/stub.out")"
check "stub resume pushed content" "$(test -n "$(remote_head charlie)"; echo $?)" ""
check "stub clone used the file:// url for origin" "$([[ "$(git -C "$ROOT/C/charlie" remote get-url origin)" == "$(ssh_url charlie)" ]]; echo $?)" ""
check "cloned dir has marker" "$([[ "$(cat "$ROOT/C/charlie/.opencode/toolkit")" == "remote_opencode_sync" ]]; echo $?)" ""

echo "== D. genuine collision is refused =="
mkdir -p "$ROOT/D"
mkbare evicted
seed_remote "$GH_FAKE_ROOT/fakeuser/evicted.git"
( cd "$ROOT/D" && "$ROE/scripts/new-project.sh" evicted > "$ROOT/D/col.out" 2>&1 )
expect_exit "genuine collision exits non-zero" 1 $? "$(tail -n2 "$ROOT/D/col.out")"
check "collision says repo is not an empty stub" "$(grep -q 'not an empty stub' "$ROOT/D/col.out"; echo $?)" ""
check "collision did not create a local dir" "$(test ! -d "$ROOT/D/evicted"; echo $?)" ""

echo "== E. adopt resume: repo exists -> skip create =="
mkdir -p "$ROOT/E/legacy/bin"
printf '#!/bin/sh\necho hi\n' > "$ROOT/E/legacy/bin/run"
git -C "$ROOT/E/legacy" init -q -b main
( cd "$ROOT/E/legacy" && git add -A && git -c user.email=t@t -c user.name=t commit -qm "so it begins" )
mkbare legacy
( cd "$ROOT/E" && "$ROE/scripts/new-project.sh" --existing legacy --name legacy --model opencode/big-pickle > "$ROOT/E/adopt.out" 2>&1 )
expect_exit "adopt of pre-existing repo succeeds" 0 $? "$(tail -n2 "$ROOT/E/adopt.out")"
check "adopt set origin on the project (not the invoker's cwd)" "$([[ "$(git -C "$ROOT/E/legacy" remote get-url origin)" == "$(ssh_url legacy)" ]]; echo $?)" ""
check "adopt kept local history (oldest commit preserved)" "$([[ "$(git -C "$ROOT/E/legacy" log --format=%s | tail -n1)" == "so it begins" ]]; echo $?)" "$(git -C "$ROOT/E/legacy" log --format=%s)"
check "adopt added the sync seed commit" "$(test "$(git -C "$ROOT/E/legacy" log --oneline | wc -l)" -ge 2; echo $?)" ""
check "adopt pushed everything" "$([[ "$(git -C "$ROOT/E/legacy" log --oneline -1)" == "$(remote_head legacy)" ]]; echo $?)" ""
check "adopt pinned the model" "$(grep -q '"model": "opencode/big-pickle"' "$ROOT/E/legacy/opencode.jsonc"; echo $?)" ""

echo "== E2. adopt hardening: dirty tree, origin repoint, branch/default, tags =="
mkdir -p "$ROOT/E2/dirtyproj"
git -C "$ROOT/E2/dirtyproj" init -q -b main
( cd "$ROOT/E2/dirtyproj" && printf '#!/bin/sh\necho hi\n' > script.sh && git add -A && git -c user.email=t@t -c user.name=t commit -qm base && printf 'work in progress\n' > wip.txt && printf 'draft\n' > draft.md )
mkbare dirtyproj
( cd "$ROOT/E2" && "$ROE/scripts/new-project.sh" --existing dirtyproj --name dirtyproj --model opencode/big-pickle > "$ROOT/E2/dirty.out" 2>&1 )
expect_exit "adopt of a dirty tree succeeds (warn + continue)" 0 $? "$(tail -n2 "$ROOT/E2/dirty.out")"
check "warns pre-existing changes are included" "$(grep -q 'pre-existing change' "$ROOT/E2/dirty.out"; echo $?)" ""
check "uncommitted file traveled in the import commit" "$(git -C "$ROOT/E2/dirtyproj" show HEAD:wip.txt 2>/dev/null | grep -q 'work in progress'; echo $?)" ""

mkdir -p "$ROOT/E2/oldorigin"
git -C "$ROOT/E2/oldorigin" init -q -b main
( cd "$ROOT/E2/oldorigin" && git remote add origin "https://github.com/other/beta-old.git" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m base )
mkbare oldorigin
( cd "$ROOT/E2" && "$ROE/scripts/new-project.sh" --existing oldorigin --name oldorigin --force > "$ROOT/E2/repoint.out" 2>&1 )
expect_exit "adopt --force repoints a foreign origin" 0 $? "$(tail -n2 "$ROOT/E2/repoint.out")"
check "repoint notice names the old origin" "$(grep -q 'previous origin' "$ROOT/E2/repoint.out"; echo $?)" ""
check "origin now points at the toolkit repo" "$([[ "$(git -C "$ROOT/E2/oldorigin" remote get-url origin)" == "$(ssh_url oldorigin)" ]]; echo $?)" "$(git -C "$ROOT/E2/oldorigin" remote get-url origin)"

mkdir -p "$ROOT/E2/branchy"
git -C "$ROOT/E2/branchy" init -q -b develop
( cd "$ROOT/E2/branchy" && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m base && git tag -a v1.0 -m v1.0 )
mkbare branchy
( cd "$ROOT/E2" && "$ROE/scripts/new-project.sh" --existing branchy --name branchy > "$ROOT/E2/branch.out" 2>&1 )
expect_exit "adopt pushes a non-default branch" 0 $? "$(tail -n2 "$ROOT/E2/branch.out")"
check "hints when pushed branch differs from remote default" "$(grep -q 'default branch' "$ROOT/E2/branch.out"; echo $?)" ""
check "pushed ref is the local branch (develop)" "$(git --git-dir "$GH_FAKE_ROOT/fakeuser/branchy.git" show-ref --verify --quiet refs/heads/develop; echo $?)" ""
check "annotated tag traveled to the remote" "$(git --git-dir "$GH_FAKE_ROOT/fakeuser/branchy.git" tag | grep -q '^v1.0$'; echo $?)" ""

echo "== F. projects + clone =="
mkbare plain1
seed_remote "$GH_FAKE_ROOT/fakeuser/plain1.git"
mkbare stub1

mkdir -p "$ROOT/F"
( cd "$ROOT/F" && "$ROE/scripts/projects.sh" list > "$ROOT/F/list.out" 2>&1 )
expect_exit "projects list exits 0" 0 $? "$(tail -n2 "$ROOT/F/list.out")"
check "lists alpha" "$(grep -q '^alpha' "$ROOT/F/list.out"; echo $?)" ""
check "lists plain1" "$(grep -q '^plain1' "$ROOT/F/list.out"; echo $?)" ""
check "reports synced count" "$(grep -qE '[0-9]+ synced of [0-9]+' "$ROOT/F/list.out"; echo $?)" ""
( cd "$ROOT/F" && "$ROE/scripts/projects.sh" list alpha > "$ROOT/F/filt.out" 2>&1 )
check "substring filter narrows to alpha" "$(grep -q '^alpha' "$ROOT/F/filt.out"; echo $?)" ""
check "filtered list omits plain1" "$(! grep -q plain1 "$ROOT/F/filt.out"; echo $?)" ""
check "cache file created" "$(test -f "$HOME/.cache/remote_opencode_sync/projects.json"; echo $?)" ""
mkbare polished
( cd "$(mktemp -d)" && git init -q -b main . && mkdir -p .opencode && printf 'remote_opencode_sync\n' > .opencode/toolkit && echo z > z.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm c && git push -q "file://$GH_FAKE_ROOT/$GH_FAKE_OWNER/polished.git" main)
( cd "$ROOT/F" && "$ROE/scripts/projects.sh" list --refresh > "$ROOT/F/refresh.out" 2>&1 )
check "--refresh lists polished" "$(grep -q '^polished' "$ROOT/F/refresh.out"; echo $?)" ""
ROOT_F="$ROOT/F" ROE="$ROE/scripts/projects.sh" OUT="$ROOT/F/off.out" GH_FAKE_ROOT="$ROOT/nowhere" bash -c 'cd "$ROOT_F" && "$ROE" list --refresh > "$OUT" 2>&1' bash
check "offline --refresh now shows cached rows" "$(grep -q '^alpha' "$ROOT/F/off.out"; echo $?)" ""
check "offline run notes the cached fallback" "$(grep -q 'cached' "$ROOT/F/off.out"; echo $?)" ""

mkdir -p "$ROOT/F2" && cd "$ROOT/F2"
"$ROE/scripts/projects.sh" clone alpha > "$ROOT/F2/clone.out" 2>&1
expect_exit "clone exits 0" 0 $? "$(tail -n2 "$ROOT/F2/clone.out")"
check "clone carried the marker" "$([[ "$(cat alpha/.opencode/toolkit)" == "remote_opencode_sync" ]]; echo $?)" ""
check "clone printed Next hint" "$(grep -q 'Next: cd alpha && opencode' "$ROOT/F2/clone.out"; echo $?)" ""
"$ROE/scripts/projects.sh" clone plain1 > "$ROOT/F2/clonep.out" 2>&1
expect_exit "clone refuses a non-synced repo" 1 $? "$(tail -n2 "$ROOT/F2/clonep.out")"
check "clone rejection suggests adopt" "$(grep -q 'roe adopt' "$ROOT/F2/clonep.out"; echo $?)" ""
"$ROE/scripts/projects.sh" clone alpha > "$ROOT/F2/clone2.out" 2>&1
expect_exit "clone of existing local dir refused" 1 $? "$(tail -n2 "$ROOT/F2/clone2.out")"

echo "== G. desync / resync =="
cd "$ROOT/F2/alpha"
"$ROE/scripts/desync.sh" -y > "$ROOT/F2/desync.out" 2>&1
expect_exit "desync exits 0" 0 $? "$(tail -n2 "$ROOT/F2/desync.out")"
check "opt-out file created" "$(test -f .opencode/state/no-session-sync; echo $?)" ""
check "opt-out file is gitignored" "$(git check-ignore -q .opencode/state/no-session-sync; echo $?)" ""
check "AGENTS.md rules stripped locally" "$(! grep -q '## 1. Session start' AGENTS.md; echo $?)" ""
check "AGENTS.md overview kept" "$(grep -q '## Project overview' AGENTS.md; echo $?)" ""
check "desync left the tree clean (skip-worktree + ignored state)" "$(test -z "$(git status --porcelain)"; echo $?)" ""
"$ROE/scripts/desync.sh" -y > "$ROOT/F2/desync2.out" 2>&1
expect_exit "desync is idempotent" 0 $? "$(tail -n1 "$ROOT/F2/desync2.out")"
check "re-run reports already-desynced" "$(grep -q 'already desynced' "$ROOT/F2/desync2.out"; echo $?)" ""
"$ROE/scripts/resync.sh" > "$ROOT/F2/resync.out" 2>&1
expect_exit "resync exits 0" 0 $? "$(tail -n1 "$ROOT/F2/resync.out")"
check "opt-out removed" "$(test ! -f .opencode/state/no-session-sync; echo $?)" ""
check "AGENTS.md rules restored" "$(grep -q '## 1. Session start' AGENTS.md; echo $?)" ""
check "tree clean after resync" "$(test -z "$(git status --porcelain)"; echo $?)" ""

mkdir -p "$ROOT/G" && cd "$ROOT/G"
git init -q -b main . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m x
"$ROE/scripts/desync.sh" -y > "$ROOT/G/noop.out" 2>&1
expect_exit "desync refuses non-toolkit project" 1 $? "$(tail -n1 "$ROOT/G/noop.out")"

echo "== H. roe front-end smoke =="
cd "$ROOT"
"$ROE/bin/roe" projects > "$ROOT/roep.out" 2>&1
check "roe projects dispatch works" "$(grep -q 'remote_opencode_sync projects for fakeuser' "$ROOT/roep.out"; echo $?)" ""
"$ROE/bin/roe" --help > "$ROOT/roeh.out" 2>&1
check "roe help lists new commands" "$(grep -qE 'projects|clone|desync|resync' "$ROOT/roeh.out"; echo $?)" ""

echo "== I. toolkit repo self-hosts itself =="
check "repo root carries the toolkit marker" "$([[ -f "$ROE/.opencode/toolkit" && "$(cat "$ROE/.opencode/toolkit")" == "remote_opencode_sync" ]]; echo $?)" ""
check "repo config pins model + fallback commands" "$(grep -q '"model": "opencode/big-pickle"' "$ROE/opencode.jsonc" && test "$(grep -c '"template"' "$ROE/opencode.jsonc")" -ge 3; echo $?)" ""
check "CONTINUE.md carries the running handoff" "$(grep -q '^## LAST SESSION' "$ROE/CONTINUE.md"; echo $?)" ""
check "AGENTS.md carries the session-start rules header" "$(grep -q '^## 1\. Session start' "$ROE/AGENTS.md"; echo $?)" ""

echo
echo "features.sh: $OK checks, $FAIL failed"
exit $((FAIL ? 1 : 0))