#!/usr/bin/env bash

fixture_make_package() {
  local root="$1" layout="$2" package_name="$3" package_version="$4"
  mkdir -p "$root"
  printf '{"name":"%s","version":"%s"}\n' "$package_name" "$package_version" >"$root/package.json"

  case "$layout" in
    single-cjs)
      printf '#!/usr/bin/env node\nmodule.exports = {}\n' >"$root/cli.js"
      ;;
    split-esm)
      mkdir -p "$root/chunks"
      printf '#!/usr/bin/env node\nimport "./chunks/main.js"\n' >"$root/cli.js"
      printf 'export const ready = true\n' >"$root/chunks/main.js"
      ;;
    *)
      printf 'unsupported fixture layout: %s\n' "$layout" >&2
      return 1
      ;;
  esac
}

fixture_entry() {
  printf '%s/cli.js\n' "$1"
}

fixture_add_module() {
  local root="$1" relative_path="$2" source="$3"
  mkdir -p "$(dirname "$root/$relative_path")"
  printf '%s\n' "$source" >"$root/$relative_path"
}
