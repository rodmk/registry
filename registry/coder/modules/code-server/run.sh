#!/usr/bin/env bash

EXTENSIONS=("${EXTENSIONS}")
BOLD='\033[0;1m'
CODE='\033[36;40;1m'
RESET='\033[0m'
CODE_SERVER="${INSTALL_PREFIX}/bin/code-server"

# Set extension directory
EXTENSION_ARG=""
if [ -n "${EXTENSIONS_DIR}" ]; then
  EXTENSION_ARG="--extensions-dir=${EXTENSIONS_DIR}"
  mkdir -p "${EXTENSIONS_DIR}"
fi

function run_code_server() {
  echo "👷 Running code-server in the background..."
  echo "Check logs at ${LOG_PATH}!"
  $CODE_SERVER "$EXTENSION_ARG" --auth none --port "${PORT}" --app-name "${APP_NAME}" ${ADDITIONAL_ARGS} > "${LOG_PATH}" 2>&1 &
}

# Check if the settings file exists...
if [ ! -f ~/.local/share/code-server/User/settings.json ]; then
  echo "⚙️ Creating settings file..."
  mkdir -p ~/.local/share/code-server/User
  if command -v jq &> /dev/null; then
    echo "${SETTINGS}" | jq '.' > ~/.local/share/code-server/User/settings.json
  else
    echo "${SETTINGS}" > ~/.local/share/code-server/User/settings.json
  fi
fi

# Apply/overwrite template based settings
echo "⚙️ Creating machine settings file..."
mkdir -p ~/.local/share/code-server/Machine
if command -v jq &> /dev/null; then
  echo "${MACHINE_SETTINGS}" | jq '.' > ~/.local/share/code-server/Machine/settings.json
else
  echo "${MACHINE_SETTINGS}" > ~/.local/share/code-server/Machine/settings.json
fi

# Check if code-server is already installed for offline
if [ "${OFFLINE}" = true ]; then
  if [ -f "$CODE_SERVER" ]; then
    echo "🥳 Found a copy of code-server"
    run_code_server
    exit 0
  fi
  # Offline mode always expects a copy of code-server to be present
  echo "Failed to find a copy of code-server"
  exit 1
fi

# If there is no cached install OR we don't want to use a cached install
if [ ! -f "$CODE_SERVER" ] || [ "${USE_CACHED}" != true ]; then
  printf "$${BOLD}Installing code-server!\n"

  # Clean up from other install (in case install prefix changed).
  if [ -n "$CODER_SCRIPT_BIN_DIR" ] && [ -e "$CODER_SCRIPT_BIN_DIR/code-server" ]; then
    rm "$CODER_SCRIPT_BIN_DIR/code-server"
  fi

  ARGS=(
    "--method=standalone"
    "--prefix=${INSTALL_PREFIX}"
  )
  if [ -n "${VERSION}" ]; then
    ARGS+=("--version=${VERSION}")
  fi

  output=$(curl -fsSL https://code-server.dev/install.sh | sh -s -- "$${ARGS[@]}")
  if [ $? -ne 0 ]; then
    echo "Failed to install code-server: $output"
    exit 1
  fi
  printf "🥳 code-server has been installed in ${INSTALL_PREFIX}\n\n"
fi

# Make the code-server available in PATH.
if [ -n "$CODER_SCRIPT_BIN_DIR" ] && [ ! -e "$CODER_SCRIPT_BIN_DIR/code-server" ]; then
  ln -s "$CODE_SERVER" "$CODER_SCRIPT_BIN_DIR/code-server"
fi

# Get the list of installed extensions...
LIST_EXTENSIONS=$($CODE_SERVER --list-extensions $EXTENSION_ARG)
readarray -t EXTENSIONS_ARRAY <<< "$LIST_EXTENSIONS"
function extension_installed() {
  if [ "${USE_CACHED_EXTENSIONS}" != true ]; then
    return 1
  fi
  # shellcheck disable=SC2066
  for _extension in "$${EXTENSIONS_ARRAY[@]}"; do
    if [ "$_extension" == "$1" ]; then
      echo "Extension $1 was already installed."
      return 0
    fi
  done
  return 1
}

# Install each extension...
IFS=',' read -r -a EXTENSIONLIST <<< "$${EXTENSIONS}"
# shellcheck disable=SC2066
for extension in "$${EXTENSIONLIST[@]}"; do
  if [ -z "$extension" ]; then
    continue
  fi
  if extension_installed "$extension"; then
    continue
  fi
  printf "🧩 Installing extension $${CODE}$extension$${RESET}...\n"
  output=$($CODE_SERVER "$EXTENSION_ARG" --force --install-extension "$extension")
  if [ $? -ne 0 ]; then
    echo "Failed to install extension: $extension: $output"
    exit 1
  fi
done

# Parse extension IDs from a JSONC file (extensions.json or .code-workspace).
# Uses node for full JSONC support (comments, trailing commas), falls back to sed+jq.
# $1: file path, $2: jq selector (e.g. .recommendations or .extensions.recommendations)
parse_jsonc_extensions() {
  local file="$1" selector="$2"
  if command -v node > /dev/null 2>&1; then
    node -e "
      var s = require('fs').readFileSync(process.argv[1], 'utf8')
        .replace(/\/\*[\s\S]*?\*\//g, '')
        .replace(/\/\/.*/g, '')
        .replace(/,(\s*[\]}])/g, '\$1');
      var keys = process.argv[2].split('.').filter(Boolean);
      var v = JSON.parse(s);
      for (var i = 0; i < keys.length; i++) v = (v || {})[keys[i]];
      (Array.isArray(v) ? v : []).forEach(function(e) { console.log(e); });
    " "$file" "$selector" 2> /dev/null
  elif command -v jq > /dev/null 2>&1; then
    sed 's|//.*||g' "$file" | jq -r "($selector // [])[]"
  else
    echo "Warning: node or jq is required to install extensions from a workspace file." >&2
    return 1
  fi
}

if [ "${AUTO_INSTALL_EXTENSIONS}" = true ]; then
  WORKSPACE_DIR="$HOME"
  if [ -n "${FOLDER}" ]; then
    WORKSPACE_DIR="${FOLDER}"
  fi

  if [ -f "$WORKSPACE_DIR/.vscode/extensions.json" ]; then
    printf "🧩 Installing extensions from %s/.vscode/extensions.json...\n" "$WORKSPACE_DIR"
    extensions=$(parse_jsonc_extensions "$WORKSPACE_DIR/.vscode/extensions.json" ".recommendations")
    for extension in $extensions; do
      if extension_installed "$extension"; then
        continue
      fi
      $CODE_SERVER "$EXTENSION_ARG" --force --install-extension "$extension"
    done
  fi
fi

run_code_server
