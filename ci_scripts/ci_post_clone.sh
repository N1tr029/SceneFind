#!/bin/sh
# Xcode Cloud runs this automatically after cloning the repo, before the build.
#
# It recreates SceneFindApp/Resources/PrototypeSecrets.plist from secret
# environment variables so provider keys never live in git. Set these as
# SECRET environment variables in the Xcode Cloud workflow:
#   GROQ_API_KEY    -> written as <GroqAPIKey>
#   GEMINI_API_KEY  -> written as <GeminiAPIKey>
#
# NOTE: This embeds provider keys directly in the app binary. It is intended
# for INTERNAL TestFlight testing only. Before public App Store release, move
# to the backend proxy (see docs/PRODUCTION_BACKEND.md) and ship a keyless
# build (Release config strips secrets and hard-fails if any are present).

set -e

# Xcode Cloud checks out into $CI_PRIMARY_REPOSITORY_PATH; fall back to the
# repo root relative to this script when run locally.
REPO_ROOT="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
SECRETS_FILE="${REPO_ROOT}/SceneFindApp/Resources/PrototypeSecrets.plist"

if [ -z "${GROQ_API_KEY}" ] && [ -z "${GEMINI_API_KEY}" ]; then
  echo "ci_post_clone: no GROQ_API_KEY/GEMINI_API_KEY env vars set; leaving PrototypeSecrets.plist untouched."
  exit 0
fi

mkdir -p "$(dirname "${SECRETS_FILE}")"

cat > "${SECRETS_FILE}" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>GroqAPIKey</key>
	<string>${GROQ_API_KEY}</string>
	<key>GeminiAPIKey</key>
	<string>${GEMINI_API_KEY}</string>
</dict>
</plist>
PLIST

echo "ci_post_clone: wrote PrototypeSecrets.plist (GroqAPIKey set: $([ -n "${GROQ_API_KEY}" ] && echo yes || echo no), GeminiAPIKey set: $([ -n "${GEMINI_API_KEY}" ] && echo yes || echo no))."
