#!/bin/sh
# Xcode Cloud runs this automatically after cloning, before building.
# Writes PrototypeSecrets.plist from the GEMINI_API_KEY secret environment
# variable so TestFlight builds ship with a working key. The plist path is
# gitignored and the "Embed Local Prototype Secrets" build phase copies it
# into the app bundle, where GeminiConfiguration reads it as the bundled
# default (in-app Settings/Keychain still overrides it).
set -e

if [ -z "${GEMINI_API_KEY}" ]; then
  echo "GEMINI_API_KEY not set; skipping PrototypeSecrets.plist (app will require in-app key entry)"
  exit 0
fi

SECRETS_FILE="${CI_PRIMARY_REPOSITORY_PATH}/SceneFindApp/Resources/PrototypeSecrets.plist"
mkdir -p "$(dirname "${SECRETS_FILE}")"
/usr/libexec/PlistBuddy -c "Add :GeminiAPIKey string ${GEMINI_API_KEY}" "${SECRETS_FILE}"
echo "PrototypeSecrets.plist written to $(dirname "${SECRETS_FILE}")"
