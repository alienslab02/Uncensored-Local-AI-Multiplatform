# shellcheck shell=bash
# Load KEY=VAL pairs from a .env file without overriding already-set vars.
# Usage: _load_dotenv /path/to/.env

_load_dotenv() {
  local file="$1"
  [[ -f "$file" ]] || return 0

  local line key val
  while IFS= read -r line || [[ -n "$line" ]]; do
    # strip comments / whitespace
    line="${line%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    [[ "$line" != *=* ]] && continue

    key="${line%%=*}"
    val="${line#*=}"
    key="${key%"${key##*[![:space:]]}"}"
    key="${key#"${key%%[![:space:]]*}"}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    # strip matching quotes
    if [[ "${val}" == \"*\" && "${val}" == *\" ]]; then
      val="${val:1:${#val}-2}"
    elif [[ "${val}" == \'*\' && "${val}" == *\' ]]; then
      val="${val:1:${#val}-2}"
    fi

    [[ -z "$key" ]] && continue
    # Do not override vars already present in the environment
    if [[ -n "${!key+x}" ]]; then
      continue
    fi
    export "${key}=${val}"
  done <"$file"
}
