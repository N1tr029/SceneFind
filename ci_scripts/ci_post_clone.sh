#!/bin/sh
# Xcode Cloud runs this automatically after cloning the repository.
#
# Production and TestFlight builds use the SceneFind backend. Provider keys
# must be configured only as backend secrets and are never materialized in the
# iOS checkout or copied into an app bundle.

set -eu

if [ -n "${GROQ_API_KEY:-}" ] || [ -n "${GEMINI_API_KEY:-}" ] || [ -n "${SEARCH_API_KEY:-}" ]; then
  echo "error: Provider secrets must not be configured in the iOS Xcode Cloud workflow. Configure them on the backend."
  exit 1
fi

echo "ci_post_clone: keyless iOS build confirmed."
