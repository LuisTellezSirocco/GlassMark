#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT="$ROOT_DIR/GlassMark.xcodeproj"
SCHEME="GlassMark"
DERIVED_DATA="$ROOT_DIR/DerivedData"
CONFIGURATION="Debug"

if [[ ! -d "$PROJECT" ]]; then
  echo "Missing GlassMark.xcodeproj. Run: xcodegen generate"
  exit 1
fi

pkill -x Glassmark >/dev/null 2>&1 || true

xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -configuration "$CONFIGURATION" \
  -derivedDataPath "$DERIVED_DATA" \
  build

APP_PATH="$DERIVED_DATA/Build/Products/$CONFIGURATION/Glassmark.app"
ENV_FILE="$ROOT_DIR/.env"

# Launches the built app. When .env defines GEMINI_API_KEY it is passed through the
# environment — never argv, which would expose it in `ps`. open(1) does not
# propagate the caller's environment, so the executable is started directly.
launch_app() {
  local env_key=""
  if [[ -f "$ENV_FILE" ]] && grep -q '^GEMINI_API_KEY=' "$ENV_FILE"; then
    env_key="$(sed -n 's/^GEMINI_API_KEY=//p' "$ENV_FILE" | head -n 1 | tr -d '"' | tr -d "'" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
  fi

  if [[ -n "$env_key" ]]; then
    GEMINI_API_KEY="$env_key" "$APP_PATH/Contents/MacOS/Glassmark" >/dev/null 2>&1 &
    echo "Launched with GEMINI_API_KEY from .env (development credential)."
  else
    open -n "$APP_PATH"
  fi
}

case "${1:-}" in
  --verify)
    test -d "$APP_PATH"
    echo "Verified build artifact: $APP_PATH"
    ;;
  --logs)
    launch_app
    log stream --style compact --predicate 'process == "Glassmark"'
    ;;
  *)
    launch_app
    ;;
esac
