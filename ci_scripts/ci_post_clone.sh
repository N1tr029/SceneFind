#!/bin/sh
# Xcode Cloud runs this automatically after cloning the repository.
#
# Production and TestFlight builds use the SceneFind backend. Provider keys
# must be configured only as backend secrets and are never materialized in the
# iOS checkout or copied into an app bundle.

set -eu

if [ -n "${GROQ_API_KEY:-}" ] || [ -n "${GEMINI_API_KEY:-}" ] || [ -n "${SEARCH_API_KEY:-}" ]; then
  # Older workflow revisions may still define these variables. They are not
  # consumed by the iOS target, and the release build phase scans the finished
  # bundle for provider-secret patterns before allowing an archive to finish.
  echo "warning: Ignoring stale provider variables in Xcode Cloud; remove them from the workflow when convenient."
fi

echo "ci_post_clone: backend-backed iOS build confirmed."
