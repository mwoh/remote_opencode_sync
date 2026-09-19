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
check "scan passes owner positionally (gh repo list has no --owner)" "$(grep -q 'repo list "$own"' "$ROE/scripts/projects.sh"; echo $?)" ""
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
check "roe help lists new commands" "$(grep -qE 'projects|clone|desync|resync|status|pull|push|upgrade' "$ROOT/roeh.out"; echo $?)" ""

echo "== I. toolkit repo self-hosts itself =="
check "repo root carries the toolkit marker" "$([[ -f "$ROE/.opencode/toolkit" && "$(cat "$ROE/.opencode/toolkit")" == "remote_opencode_sync" ]]; echo $?)" ""
check "repo config pins model + fallback commands" "$(grep -q '"model": "opencode/big-pickle"' "$ROE/opencode.jsonc" && test "$(grep -c '"template"' "$ROE/opencode.jsonc")" -ge 3; echo $?)" ""
check "CONTINUE.md carries the running handoff" "$(grep -q '^## LAST SESSION' "$ROE/CONTINUE.md"; echo $?)" ""
check "AGENTS.md carries the session-start rules header" "$(grep -q '^## 1\. Session start' "$ROE/AGENTS.md"; echo $?)" ""

echo "== J. roe version reports installed vs latest =="
check "semver sort picks v1.5.10 over v1.5.9 (with ^{} + junk filtered)" "$([[ "$(printf 'refs/tags/v1.5.9\nrefs/tags/v1.5.10\nrefs/tags/v1.5.5^{}\nfoo\n' | ver_sort_max)" == "v1.5.10" ]]; echo $?)" ""
mkdir -p "$ROOT/J/tool/bin" "$ROOT/J/tool/scripts"
cp "$ROE/bin/roe" "$ROOT/J/tool/bin/roe"
cp "$ROE/scripts/lib.sh" "$ROOT/J/tool/scripts/lib.sh"
git -C "$ROOT/J/tool" init -q -b main
( cd "$ROOT/J/tool" && git add -A && git -c user.email=t@t -c user.name=t commit -qm base && git tag v1.5.4 )
mkbare roletool
tmpj="$(mktemp -d)"
( cd "$tmpj" && git init -q -b main . && git -c user.email=t@t -c user.name=t commit -q --allow-empty -m base && git tag v1.5.4 && git tag v1.5.5 && git push -q "$GH_FAKE_ROOT/$GH_FAKE_OWNER/roletool.git" main --tags )
git -C "$ROOT/J/tool" remote add origin "$(ssh_url roletool)"
"$ROOT/J/tool/bin/roe" version > "$ROOT/J/ver-up.out" 2>&1
check "version prints installed + latest when behind" "$(grep -q 'remote_opencode_sync v1.5.4' "$ROOT/J/ver-up.out" && grep -q 'latest: v1.5.5' "$ROOT/J/ver-up.out"; echo $?)" ""
check "version suggests roe update when behind" "$(grep -q 'roe update' "$ROOT/J/ver-up.out"; echo $?)" ""
git -C "$ROOT/J/tool" -c user.email=t@t -c user.name=t commit -q --allow-empty -m later
git -C "$ROOT/J/tool" tag v1.5.5
"$ROOT/J/tool/bin/roe" version > "$ROOT/J/ver-ok.out" 2>&1
check "version reports up to date when current" "$(grep -q 'up to date' "$ROOT/J/ver-ok.out"; echo $?)" ""

echo "== K. roe status / pull / push / upgrade =="
echo "  K1: status — healthy project, dispatch, model + states"
mkdir -p "$ROOT/K"
( cd "$ROOT/K" && "$ROE/scripts/projects.sh" clone alpha > "$ROOT/K/clone.out" 2>&1 )
"$ROE/bin/roe" status "$ROOT/K/alpha" > "$ROOT/K/stat-ok.out" 2>&1
expect_exit "roe status (healthy) exits 0" 0 $? "$(tail -n1 "$ROOT/K/stat-ok.out")"
check "status reports all caught up" "$(grep -q 'all caught up' "$ROOT/K/stat-ok.out"; echo $?)" ""
check "status reports the pinned model" "$(grep -q 'model: opencode/big-pickle' "$ROOT/K/stat-ok.out"; echo $?)" ""
mkdir -p "$ROOT/K/plain" && git -C "$ROOT/K/plain" init -q -b main && git -C "$ROOT/K/plain" -c user.email=t@t -c user.name=t commit -q --allow-empty -m x
"$ROE/scripts/status.sh" "$ROOT/K/plain" > "$ROOT/K/stat-not.out" 2>&1
expect_exit "status on a non-toolkit dir exits 1" 1 $? "$(tail -n1 "$ROOT/K/stat-not.out")"
check "status names the missing marker" "$(grep -q 'not a remote_opencode_sync project' "$ROOT/K/stat-not.out"; echo $?)" ""

echo "  K2: ahead -> status flags push; roe push sends it"
echo push-tile > "$ROOT/K/alpha/step.txt"
( cd "$ROOT/K/alpha" && git add -A && git -c user.email=t@t -c user.name=t commit -qm k2push )
"$ROE/scripts/status.sh" "$ROOT/K/alpha" > "$ROOT/K/stat-ahead.out" 2>&1
expect_exit "status flags an ahead project" 2 $? "$(grep 'state:' "$ROOT/K/stat-ahead.out")"
check "status recommends roe push when ahead" "$(grep -q 'roe push' "$ROOT/K/stat-ahead.out"; echo $?)" ""
"$ROE/scripts/push.sh" "$ROOT/K/alpha" > "$ROOT/K/push.out" 2>&1
expect_exit "roe push exits 0" 0 $? "$(tail -n1 "$ROOT/K/push.out")"
check "push reports committed count" "$(grep -q 'pushed 1 commit' "$ROOT/K/push.out"; echo $?)" ""
check "push reached the remote" "$([[ "$(git -C "$ROOT/K/alpha" log --oneline -1)" == "$(remote_head alpha)" ]]; echo $?)" ""
"$ROE/scripts/status.sh" "$ROOT/K/alpha" > "$ROOT/K/stat-after-push.out" 2>&1
expect_exit "status is clean again after push" 0 $? "$(tail -n1 "$ROOT/K/stat-after-push.out")"

echo "  K3: behind -> status flags pull; roe pull rebases it in"
pull_src="$ROOT/K/pull-src"
mkdir -p "$pull_src" && git clone "$(ssh_url alpha)" "$pull_src/alpha" > "$ROOT/K/pullclone.out" 2>&1
( cd "$pull_src/alpha" && echo behind-tile > remote.txt && git add -A && git -c user.email=t@t -c user.name=t commit -qm k3pull && git push > "$ROOT/K/pullpush.out" 2>&1 )
"$ROE/scripts/status.sh" "$ROOT/K/alpha" > "$ROOT/K/stat-behind.out" 2>&1
expect_exit "status flags a behind project" 2 $? "$(grep 'state:' "$ROOT/K/stat-behind.out")"
check "status recommends roe pull when behind" "$(grep -q 'roe pull' "$ROOT/K/stat-behind.out"; echo $?)" ""
"$ROE/scripts/pull.sh" "$ROOT/K/alpha" > "$ROOT/K/pull.out" 2>&1
expect_exit "roe pull exits 0" 0 $? "$(tail -n1 "$ROOT/K/pull.out")"
check "pull reports it fetched" "$(grep -q 'pulled' "$ROOT/K/pull.out"; echo $?)" ""
check "pull leaves the copy at the remote head" "$([[ "$(git -C "$ROOT/K/alpha" log --oneline -1)" == "$(remote_head alpha)" ]]; echo $?)" ""
check "pull applied the remote file" "$(grep -q behind-tile "$ROOT/K/alpha/remote.txt"; echo $?)" ""
"$ROE/scripts/status.sh" "$ROOT/K/alpha" > "$ROOT/K/stat-after-pull.out" 2>&1
expect_exit "status is clean again after pull" 0 $? "$(tail -n1 "$ROOT/K/stat-after-pull.out")"

echo "  K4: dirty tree -> status flags uncommitted work"
echo dirty-tile > "$ROOT/K/alpha/wip.txt"
"$ROE/scripts/status.sh" "$ROOT/K/alpha" > "$ROOT/K/stat-dirty.out" 2>&1
expect_exit "status flags a dirty tree" 2 $? "$(grep 'state:' "$ROOT/K/stat-dirty.out")"
check "status mentions the uncommitted file" "$(grep -q 'uncommitted' "$ROOT/K/stat-dirty.out"; echo $?)" ""
rm -f "$ROOT/K/alpha/wip.txt"

echo "  K5: seed drift -> status flags upgrade; roe upgrade restores + pushes"
sed -i '/^  "command": {/,/^  }$/d' "$ROOT/K/alpha/opencode.jsonc"
( cd "$ROOT/K/alpha" && git add -A && git -c user.email=t@t -c user.name=t commit -qm "drain commands" )
"$ROE/scripts/status.sh" "$ROOT/K/alpha" > "$ROOT/K/stat-drift.out" 2>&1
expect_exit "status flags a drifted seed" 2 $? "$(grep 'seed:' "$ROOT/K/stat-drift.out")"
check "status recommends roe upgrade" "$(grep -q 'roe upgrade' "$ROOT/K/stat-drift.out"; echo $?)" ""
"$ROE/bin/roe" upgrade "$ROOT/K/alpha" > "$ROOT/K/up.out" 2>&1
expect_exit "roe upgrade exits 0" 0 $? "$(tail -n1 "$ROOT/K/up.out")"
check "upgrade restored the fallback command block" "$(grep -q '"resume"' "$ROOT/K/alpha/opencode.jsonc"; echo $?)" "$(tail -n3 "$ROOT/K/up.out")"
check "upgrade kept the pinned model" "$(grep -q '"model": "opencode/big-pickle"' "$ROOT/K/alpha/opencode.jsonc"; echo $?)" ""
check "upgrade commit reached the remote" "$([[ "$(git -C "$ROOT/K/alpha" log --oneline -1)" == "$(remote_head alpha)" ]]; echo $?)" ""
k6_commits="$(git -C "$ROOT/K/alpha" log --oneline | wc -l | tr -d ' ')"
"$ROE/scripts/upgrade.sh" "$ROOT/K/alpha" > "$ROOT/K/up2.out" 2>&1
expect_exit "upgrade is idempotent (nothing to update)" 0 $? "$(tail -n1 "$ROOT/K/up2.out")"
check "second upgrade says nothing to update" "$(grep -q 'nothing to update' "$ROOT/K/up2.out"; echo $?)" ""
check "second upgrade created no new commit" "$(test "$k6_commits" = "$(git -C "$ROOT/K/alpha" log --oneline | wc -l | tr -d ' ')"; echo $?)" "k6=$k6_commits now=$(git -C "$ROOT/K/alpha" log --oneline | wc -l | tr -d ' ')"

echo "  K6: upgrade recreates a config-less / AGENTS-less legacy project"
( cd "$ROOT/K/alpha" && git rm -q opencode.jsonc AGENTS.md && git -c user.email=t@t -c user.name=t commit -qm "legacy, pre-roe" )
"$ROE/scripts/upgrade.sh" "$ROOT/K/alpha" > "$ROOT/K/up3.out" 2>&1
expect_exit "upgrade recreates missing seed files" 0 $? "$(tail -n1 "$ROOT/K/up3.out")"
check "upgrade created opencode.jsonc" "$(grep -q 'created opencode.jsonc' "$ROOT/K/up3.out"; echo $?)" ""
check "upgrade created AGENTS.md with the rules header" "$(grep -q '^## 1\. Session start' "$ROOT/K/alpha/AGENTS.md"; echo $?)" ""
check "recreated config carries the command block" "$(grep -q '"resume"' "$ROOT/K/alpha/opencode.jsonc"; echo $?)" ""
check "recreate commit reached the remote" "$([[ "$(git -C "$ROOT/K/alpha" log --oneline -1)" == "$(remote_head alpha)" ]]; echo $?)" ""

echo "  K7: status on a desynced copy flags the opt-out"
( cd "$ROOT/K/alpha" && "$ROE/scripts/desync.sh" -y > /dev/null 2>&1 )
"$ROE/scripts/status.sh" "$ROOT/K/alpha" > "$ROOT/K/stat-desync.out" 2>&1
expect_exit "status flags a desynced copy" 2 $? "$(grep 'state:\|desynced' "$ROOT/K/stat-desync.out")"
check "status names the opt-out" "$(grep -q 'desynced on this machine' "$ROOT/K/stat-desync.out"; echo $?)" ""
( cd "$ROOT/K/alpha" && "$ROE/scripts/resync.sh" > /dev/null 2>&1 )

echo "== L. roe track — see and change what a project syncs =="
L="$ROOT/L"
check "track_tui.py compiles (python3 stdlib only)" "$(python3 -m py_compile "$ROE/scripts/track_tui.py" 2>/dev/null; echo $?)" ""
mkdir -p "$L/proj/dir" "$L/proj/.opencode" "$L/proj/node_modules"
( cd "$L/proj" && git init -q -b main )
printf 'remote_opencode_sync\n' > "$L/proj/.opencode/toolkit"
( cd "$L/proj" && git add .opencode/toolkit && git -c user.email=t@t -c user.name=t commit -qm init )
echo tracked > "$L/proj/tracked.txt"
( cd "$L/proj" && git add tracked.txt && git -c user.email=t@t -c user.name=t commit -qm add-tracked )
echo fresh > "$L/proj/new.txt"
echo pkg > "$L/proj/node_modules/pkg.js"
printf 'node_modules/\n' > "$L/proj/.gitignore"   # a USER rule, outside the roe block
TRACK="$ROE/scripts/track.sh"

echo "  L1: walk-up from a subdir resolves the project root"
( cd "$L/proj/dir" && "$TRACK" --list . ) > "$L/l1.out" 2>&1
check "track walk-up resolves the root" "$(grep -q "Project: proj @ $L/proj" "$L/l1.out"; echo $?)" "$(head -n1 "$L/l1.out")"

echo "  L2: --list shows the three states"
"$TRACK" --list "$L/proj" > "$L/l2.out" 2>&1
check "tracked pane lists a committed file" "$(grep -q '^T	tracked.txt' "$L/l2.out"; echo $?)" ""
check "untracked pane lists a fresh file" "$(grep -q '^U	new.txt' "$L/l2.out"; echo $?)" ""
check "ignored pane lists a user-rule file" "$(grep -q '^I	node_modules/pkg.js' "$L/l2.out"; echo $?)" ""

echo "  L3: roe track dispatch + TUI fallback off a terminal"
"$ROE/bin/roe" track --list "$L/proj" > "$L/l3.out" 2>&1
expect_exit "roe track --list dispatches" 0 $? "$(tail -n1 "$L/l3.out")"
check "roe track names the project" "$(grep -q 'Project: proj @' "$L/l3.out"; echo $?)" ""
"$ROE/bin/roe" track "$L/proj" < /dev/null > "$L/l3b.out" 2>&1
expect_exit "roe track falls back to a text report off a TTY" 0 $? "$(tail -n1 "$L/l3b.out")"
check "fallback report lists tracked files" "$(grep -q 'tracked.txt' "$L/l3b.out"; echo $?)" ""

echo "  L4: ignore an untracked file -> moves it to the ignored pane"
"$TRACK" --ignore new.txt --dir "$L/proj" > "$L/l4.out" 2>&1
expect_exit "ignore untracked exits 0" 0 $? "$(tail -n1 "$L/l4.out")"
check "ignore reports the added pattern" "$(grep -q 'pattern .new.txt. added to the roe block' "$L/l4.out"; echo $?)" "$(tail -n1 "$L/l4.out")"
"$TRACK" --list "$L/proj" > "$L/l4b.out" 2>&1
check "file now sits in the ignored pane" "$(grep -q '^I	new.txt' "$L/l4b.out"; echo $?)" ""
if grep -q '^U	new.txt' "$L/l4b.out"; then f "file still in the untracked pane"; else t; echo "  ok ${OK}  file no longer in the untracked pane"; fi

echo "  L5: ignore a tracked file -> untracks (git rm --cached) but keeps it on disk"
"$TRACK" --ignore tracked.txt --dir "$L/proj" > "$L/l5.out" 2>&1
expect_exit "ignore tracked exits 0" 0 $? "$(tail -n1 "$L/l5.out")"
check "softer says removed from tracking" "$(grep -q 'removed from tracking (git rm --cached)' "$L/l5.out"; echo $?)" ""
check "file still exists on disk" "$([[ -f "$L/proj/tracked.txt" ]]; echo $?)" ""
check "file no longer in git index" "$([[ -z "$(git -C "$L/proj" ls-files tracked.txt)" ]]; echo $?)" "$(git -C "$L/proj" ls-files tracked.txt)"

echo "  L6: re-ignore is idempotent"
"$TRACK" --ignore new.txt --dir "$L/proj" > "$L/l6.out" 2>&1
expect_exit "re-ignore exits 0" 0 $? "$(tail -n1 "$L/l6.out")"
check "re-ignore says already ignored" "$(grep -q 'already ignored' "$L/l6.out"; echo $?)" ""
check "pattern added exactly once" "$([[ "$(grep -c '^new.txt$' "$L/proj/.gitignore")" == "1" ]]; echo $?)" "$(grep -c '^new.txt$' "$L/proj/.gitignore")"

echo "  L7: unignore restores a file to the sync set"
"$TRACK" --unignore new.txt --dir "$L/proj" > "$L/l7.out" 2>&1
expect_exit "unignore exits 0" 0 $? "$(tail -n1 "$L/l7.out")"
check "unignore removed the pattern" "$(grep -q 'rule removed from the roe block' "$L/l7.out"; echo $?)" "$(tail -n1 "$L/l7.out")"
"$TRACK" --list "$L/proj" > "$L/l7b.out" 2>&1
check "file is tracked (re-added) again" "$(grep -q '^T	new.txt' "$L/l7b.out"; echo $?)" ""

echo "  L8: a rule outside the roe block is never touched"
"$TRACK" --unignore node_modules/pkg.js --dir "$L/proj" > "$L/l8.out" 2>&1
expect_exit "unignore of a user rule exits 1" 1 $? "$(tail -n1 "$L/l8.out")"
check "refusal names the roe block" "$(grep -q 'outside the roe block' "$L/l8.out"; echo $?)" ""
check "user rule left intact" "$(grep -q '^node_modules/$' "$L/proj/.gitignore"; echo $?)" ""

echo "  L9: paths outside the project root are refused"
"$TRACK" --ignore ../../escape.txt --dir "$L/proj" > "$L/l9.out" 2>&1
expect_exit "escaping path exits 1" 1 $? "$(tail -n1 "$L/l9.out")"
check "refusal names the project root" "$(grep -q 'outside the project root' "$L/l9.out"; echo $?)" ""

echo "  L10: not a roe project is refused"
mkdir -p "$L/plain" && git -C "$L/plain" init -q -b main
"$TRACK" --list "$L/plain" > "$L/l10.out" 2>&1
expect_exit "track on a non-roe dir exits 1" 1 $? "$(tail -n1 "$L/l10.out")"
check "refusal names the marker" "$(grep -q 'not a remote_opencode_sync project' "$L/l10.out"; echo $?)" ""

echo "== M. roe history — per-machine session-history archive =="
M="$ROOT/M"
HIST="$ROE/scripts/history.sh"
mkdir -p "$M/proj/sub" "$M/other" "$M/plain" "$M/db"
( cd "$M/proj" && git init -q -b main )
mkdir -p "$M/proj/.opencode"
printf 'remote_opencode_sync\n' > "$M/proj/.opencode/toolkit"
git -C "$M/plain" init -q -b main
DB="$M/db/opencode.db"
python3 - "$DB" "$M/proj" "$M/other" <<'PY'
import sqlite3, sys
db, proj, other = sys.argv[1:4]
c = sqlite3.connect(db)
c.executescript(
    "create table project(id text, worktree text);"
    "create table project_directory(project_id text, directory text);"
    "create table session(id text, project_id text, directory text, parent_id text,"
    " title text, agent text, model text, time_created integer, time_updated integer);"
    "create table message(id text, session_id text, time_created integer, data text);"
    "create table part(id text, message_id text, session_id text, time_created integer, data text);"
)
c.executemany("insert into project values(?,?)", [("pa", proj), ("pb", other)])
c.executemany("insert into project_directory values(?,?)", [("pa", proj), ("pb", other)])
S = [
    ("ses_first", "pa", proj, "Alpha first", '{"id":"opencode/big-pickle"}', 1000, 2000),
    ("ses_second", "pa", proj, "Alpha second", '', 3000, 4000),
    ("ses_other", "pb", other, "Other project", '', 5000, 6000),
]
c.executemany(
    "insert into session(id,project_id,directory,title,model,time_created,time_updated)"
    " values(?,?,?,?,?,?,?)", S)
MESSAGES = [
    ("msg1", "ses_first", 1000, '{"role":"user"}'),
    ("msg2", "ses_first", 1100, '{"role":"assistant"}'),
    ("msg3", "ses_second", 3000, '{"role":"user"}'),
    ("msg4", "ses_other", 5000, '{"role":"user"}'),
]
c.executemany("insert into message values(?,?,?,?)", MESSAGES)
PARTS = [
    ("part1", "msg1", "ses_first", 1000, '{"type":"text","text":"hello alpha"}'),
    ("part2", "msg2", "ses_first", 1100, '{"type":"tool","tool":"bash","state":"ran"}'),
    ("part3", "msg2", "ses_first", 1101, '{"type":"text","text":"reply alpha"}'),
    ("part4", "msg3", "ses_second", 3000, '{"type":"text","text":"second question"}'),
    ("part5", "msg4", "ses_other", 5000, '{"type":"text","text":"should not appear"}'),
]
c.executemany("insert into part values(?,?,?,?,?)", PARTS)
c.commit()
PY
ARCH="$M/proj/opencode-history/testhost.jsonl.gz"

echo "  M1: the python helper compiles (python3 stdlib only)"
check "history.py compiles" "$(python3 -m py_compile "$ROE/scripts/history.py" 2>/dev/null; echo $?)" ""

echo "  M2: backup archives this project's sessions -- and only this project's"
"$HIST" backup "$M/proj" --host testhost --db "$DB" > "$M/m2.out" 2>&1
expect_exit "history backup exits 0" 0 $? "$(tail -n1 "$M/m2.out")"
check "archive written under opencode-history/" "$([[ -f "$ARCH" ]]; echo $?)" "$(tail -n1 "$M/m2.out")"
check "archive holds only this project's 2 sessions" "$([[ "$(gzip -dc "$ARCH" | grep -c .)" == "2" ]]; echo $?)" "$(gzip -dc "$ARCH" | wc -l)"
check "other project's session is excluded" "$(! gzip -dc "$ARCH" | grep -q 'Other project'; echo $?)" ""
check "own session content is present" "$(gzip -dc "$ARCH" | grep -q 'Alpha first'; echo $?)" ""

echo "  M3: re-running backup is safe (idempotent rolling archive)"
"$HIST" backup "$M/proj" --host testhost --db "$DB" > "$M/m3.out" 2>&1
expect_exit "re-backup exits 0" 0 $? "$(tail -n1 "$M/m3.out")"
check "still exactly one archive file" "$([[ "$(ls "$M/proj/opencode-history" | wc -l | tr -d ' ')" == "1" ]]; echo $?)" "$(ls "$M/proj/opencode-history")"
check "still only this project's sessions" "$([[ "$(gzip -dc "$ARCH" | grep -c .)" == "2" ]]; echo $?)" ""

echo "  M4: list renders the archive's sessions"
"$HIST" list "$M/proj" --host testhost > "$M/m4.out" 2>&1
expect_exit "history list exits 0" 0 $? "$(tail -n1 "$M/m4.out")"
check "list names the machine" "$(grep -q 'machine: testhost' "$M/m4.out"; echo $?)" ""
check "list shows both sessions" "$([[ "$(grep -cE 'Alpha first|Alpha second' "$M/m4.out")" == "2" ]]; echo $?)" ""
check "list omits the other project" "$(! grep -q 'Other project' "$M/m4.out"; echo $?)" ""

echo "  M5: show renders a readable transcript (exact id and unique prefix)"
"$HIST" show ses_first "$M/proj" --host testhost > "$M/m5.out" 2>&1
expect_exit "show <id> exits 0" 0 $? "$(tail -n1 "$M/m5.out")"
check "transcript has a title heading" "$(grep -q '^# Alpha first' "$M/m5.out"; echo $?)" ""
check "transcript includes message text" "$(grep -q 'hello alpha' "$M/m5.out"; echo $?)" ""
check "transcript marks a tool call" "$(grep -q '\[tool: bash\]' "$M/m5.out"; echo $?)" ""
"$HIST" show ses_fir "$M/proj" --host testhost > "$M/m5b.out" 2>&1
expect_exit "show with a unique prefix exits 0" 0 $? "$(tail -n1 "$M/m5b.out")"
"$HIST" show ses_ "$M/proj" --host testhost > "$M/m5c.out" 2>&1
expect_exit "ambiguous prefix is refused (exit 1)" 1 $? "$(tail -n1 "$M/m5c.out")"

echo "  M6: works from any subdirectory (project_root walk-up)"
"$HIST" backup "$M/proj/sub" --host testhost --db "$DB" > "$M/m6.out" 2>&1
expect_exit "backup from a subdir exits 0" 0 $? "$(tail -n1 "$M/m6.out")"
check "walk-up wrote the project's archive" "$([[ -f "$ARCH" ]]; echo $?)" ""

echo "  M7: failure paths are graceful"
"$HIST" list "$M/proj" --host ghost > "$M/m7.out" 2>&1
expect_exit "list with no archive exits 1" 1 $? "$(tail -n1 "$M/m7.out")"
check "missing-archive message points at backup" "$(grep -q 'roe history backup' "$M/m7.out"; echo $?)" ""
"$HIST" backup "$M/proj" --host testhost --db "$M/db/nope.db" > "$M/m7b.out" 2>&1
expect_exit "missing db exits 1" 1 $? "$(tail -n1 "$M/m7b.out")"
check "missing-db message says not found" "$(grep -q 'database not found' "$M/m7b.out"; echo $?)" ""
"$HIST" backup "$M/plain" --host testhost --db "$DB" > "$M/m7c.out" 2>&1
expect_exit "non-roe dir exits 1" 1 $? "$(tail -n1 "$M/m7c.out")"
check "non-roe message names the marker" "$(grep -q 'not a remote_opencode_sync project' "$M/m7c.out"; echo $?)" ""

echo "  M8: roe wires the history subcommand through"
"$ROE/bin/roe" history backup "$M/proj" --host testhost --db "$DB" > "$M/m8.out" 2>&1
expect_exit "roe history backup dispatches" 0 $? "$(tail -n1 "$M/m8.out")"
"$ROE/bin/roe" history list "$M/proj" --host testhost > "$M/m8b.out" 2>&1
expect_exit "roe history list dispatches" 0 $? "$(tail -n1 "$M/m8b.out")"

echo "  M9: an ignored archive is flagged as non-syncing (public-repo safety)"
printf 'opencode-history/\n' >> "$M/proj/.gitignore"
"$HIST" backup "$M/proj" --host testhost --db "$DB" > "$M/m9.out" 2>&1
expect_exit "backup still succeeds when ignored" 0 $? "$(tail -n1 "$M/m9.out")"
check "safety note says it will not sync" "$(grep -q 'will NOT sync' "$M/m9.out"; echo $?)" ""

echo
echo "features.sh: $OK checks, $FAIL failed"
exit $((FAIL ? 1 : 0))