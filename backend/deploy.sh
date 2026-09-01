#!/bin/sh
# One-command production deploy for the SceneFind Worker.
#
# Does everything that does not require your credentials:
#   1. creates the two KV namespaces and writes their real IDs into wrangler.toml
#   2. checks that every required secret is present
#   3. deploys the Worker
#   4. writes the deployed URL into project.yml for Release + TestFlight
#   5. regenerates SceneFind.xcodeproj
#
# It never reads, prints, or stores a secret value. Secrets are set by you with
# `wrangler secret put`, which prompts for the value directly.
#
# Prerequisite (once):  npx wrangler login

set -eu

cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"
WRANGLER="npx --yes wrangler@4"

say() { printf '\n\033[1m%s\033[0m\n' "$*"; }
die() { printf '\nerror: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- 1. account
say "Checking Cloudflare authentication"
$WRANGLER whoami >/dev/null 2>&1 || die "not logged in. Run: npx wrangler login"
$WRANGLER whoami | sed -n '/Account Name/,/^$/p' || true

# ------------------------------------------------------------ 2. KV namespaces
create_kv() {
  binding="$1"
  if ! grep -q "REPLACE_WITH_KV_NAMESPACE_ID" wrangler.toml; then return 0; fi
  # Already-real id for this binding? Leave it alone.
  current=$(awk -v b="$binding" '
    $0 ~ "binding = \"" b "\"" {found=1; next}
    found && /^id =/ {print; exit}' wrangler.toml | sed 's/.*"\(.*\)".*/\1/')
  case "$current" in
    REPLACE_WITH_KV_NAMESPACE_ID|"") ;;
    *) printf '  %s already bound to %s\n' "$binding" "$current"; return 0 ;;
  esac

  printf '  creating KV namespace %s ... ' "$binding"
  out=$($WRANGLER kv namespace create "$binding" 2>&1) || { printf '\n%s\n' "$out"; die "kv namespace create failed"; }
  id=$(printf '%s' "$out" | grep -oE '"?id"?[ =:]+"[0-9a-f]{32}"' | grep -oE '[0-9a-f]{32}' | head -1)
  [ -n "$id" ] || { printf '\n%s\n' "$out"; die "could not parse namespace id for $binding"; }
  printf '%s\n' "$id"

  # Replace only the placeholder that follows this binding.
  awk -v b="$binding" -v id="$id" '
    $0 ~ "binding = \"" b "\"" {found=1}
    found && /REPLACE_WITH_KV_NAMESPACE_ID/ {
      sub(/REPLACE_WITH_KV_NAMESPACE_ID/, id); found=0
    }
    { print }' wrangler.toml > wrangler.toml.tmp && mv wrangler.toml.tmp wrangler.toml
}

say "Provisioning KV namespaces"
create_kv RATE_LIMIT
create_kv WATCH_LINKS
grep -q REPLACE_WITH_KV_NAMESPACE_ID wrangler.toml && die "a KV placeholder is still unresolved in wrangler.toml"
echo "  wrangler.toml namespace ids resolved"

# ------------------------------------------------------------------ 3. secrets
say "Checking Worker secrets"
existing=$($WRANGLER secret list 2>/dev/null || echo "[]")
missing=""
for name in GEMINI_API_KEY GROQ_API_KEY APPLE_TEAM_ID APPLE_APP_ID; do
  printf '%s' "$existing" | grep -q "\"$name\"" || missing="$missing $name"
done
printf '%s' "$existing" | grep -q '"SEARCH_API_KEY"' \
  || echo "  note: SEARCH_API_KEY is unset — watch-link search will be disabled (optional)"

if [ -n "$missing" ]; then
  echo "  missing required secrets:$missing"
  echo
  echo "  Set each one now — wrangler prompts for the value, nothing is echoed:"
  for name in $missing; do echo "    npx wrangler secret put $name"; done
  echo
  echo "  APPLE_TEAM_ID is T4VT6R837D. APPLE_APP_ID is the numeric Apple ID from"
  echo "  App Store Connect > App Information (not the bundle ID)."
  die "set the secrets above, then re-run this script"
fi
echo "  all required secrets present"

# ------------------------------------------------------------------- 4. deploy
say "Verifying before deploy"
npm ci --silent
npm run typecheck
npm test

say "Deploying Worker"
deploy_out=$($WRANGLER deploy 2>&1) || { printf '%s\n' "$deploy_out"; die "deploy failed"; }
printf '%s\n' "$deploy_out"

URL=$(printf '%s' "$deploy_out" | grep -oE 'https://[a-z0-9.-]+\.workers\.dev' | head -1)
[ -n "$URL" ] || die "deploy succeeded but no workers.dev URL was found in the output; set it manually in project.yml"
say "Worker live at $URL"

printf '  smoke test GET /healthz ... '
code=$(curl -sS --tlsv1.2 --http1.1 -o /dev/null -w '%{http_code}' --max-time 20 "$URL/healthz" || echo 000)
[ "$code" = "200" ] || die "health check returned HTTP $code; the Worker deployed but is not serving"
echo "200 OK"

# --------------------------------------------------------- 5. wire into the app
say "Wiring $URL into project.yml"
python3 - "$ROOT/project.yml" "$URL" <<'PY'
import sys, re
path, url = sys.argv[1], sys.argv[2]
s = open(path).read()
n = 0
def repl(m):
    global n; n += 1
    return f'{m.group(1)}{url}'
s, _ = re.subn(r'(SCENEFIND_BACKEND_URL: )(""|\S+)', lambda m: repl(m), s)
open(path, "w").write(s)
print(f"  updated {n} SCENEFIND_BACKEND_URL entries")
assert n == 2, f"expected 2 entries, updated {n}"
PY

say "Regenerating SceneFind.xcodeproj"
(cd "$ROOT" && xcodegen generate)

say "Done"
cat <<EOF

  Backend:  $URL
  Health:   curl -sS $URL/healthz

  Next: commit and push to trigger an Xcode Cloud TestFlight build.

    git -C "$ROOT" add project.yml backend/wrangler.toml SceneFind.xcodeproj
    git -C "$ROOT" commit -m "Point the app at the deployed Worker"
    git -C "$ROOT" push origin main

EOF
