#!/bin/sh
# Xcode Cloud runs this automatically after cloning, before building.
# Writes PrototypeSecrets.plist from the GEMINI_API_KEY secret environment
# variable so TestFlight builds ship with a working key. The plist path is
# gitignored and the "Embed Local Prototype Secrets" build phase copies it
# into the app bundle, where GeminiConfiguration reads it as the bundled
# default (in-app Settings/Keychain still overrides it).
set -e

SECRETS_FILE="${CI_PRIMARY_REPOSITORY_PATH}/SceneFindApp/Resources/PrototypeSecrets.plist"

if [ -z "${GEMINI_API_KEY}" ] && [ -z "${GROQ_API_KEY}" ]; then
  echo "No GEMINI_API_KEY or GROQ_API_KEY set; skipping PrototypeSecrets.plist (app will require in-app key entry)"
  exit 0
fi

mkdir -p "$(dirname "${SECRETS_FILE}")"
/usr/libexec/PlistBuddy -c "Clear dict" "${SECRETS_FILE}" 2>/dev/null || printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">' '<plist version="1.0"><dict/></plist>' > "${SECRETS_FILE}"

if [ -n "${GEMINI_API_KEY}" ]; then
  /usr/libexec/PlistBuddy -c "Add :GeminiAPIKey string ${GEMINI_API_KEY}" "${SECRETS_FILE}"
  echo "Wrote GeminiAPIKey"
fi

# Optional: Groq powers extra episode verification; the app falls back to Gemini without it.
if [ -n "${GROQ_API_KEY}" ]; then
  /usr/libexec/PlistBuddy -c "Add :GroqAPIKey string ${GROQ_API_KEY}" "${SECRETS_FILE}"
  echo "Wrote GroqAPIKey"
fi

echo "PrototypeSecrets.plist written to $(dirname "${SECRETS_FILE}")"
