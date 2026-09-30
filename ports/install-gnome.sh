#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
extension_id='rainglass@dev.rainglass.app'
binary_dir="${HOME}/.local/bin"
extension_dir="${HOME}/.local/share/gnome-shell/extensions/${extension_id}"

if [[ -f "${script_dir}/rainglass-desktop" ]]; then
    binary_source="${script_dir}/rainglass-desktop"
else
    cargo build --release --manifest-path "${script_dir}/Cargo.toml" -p rainglass-desktop
    binary_source="${script_dir}/target/release/rainglass-desktop"
fi
install -d "${binary_dir}" "${extension_dir}"
install -m 755 "${binary_source}" "${binary_dir}/rainglass-desktop"
install -m 644 "${script_dir}/gnome-extension/${extension_id}/metadata.json" "${extension_dir}/metadata.json"
install -m 644 "${script_dir}/gnome-extension/${extension_id}/extension.js" "${extension_dir}/extension.js"

printf '%s\n' 'RainGlass installed. Log out and back in, then enable rainglass@dev.rainglass.app in GNOME Extensions.'
