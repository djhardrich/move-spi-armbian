# Armbian extension: merge the Move kernel-config fragment into the
# bcm2711 family base config during the kernel-configure step.
#
# Enabled via `enable_extension "move-kernel-config"` in
# config/boards/move.csc (Armbian does NOT auto-load files from
# userpatches/extensions/; they must be registered explicitly).
#
# Hook convention (verified against Armbian source + extensions/nomod.sh):
#   - CWD is the kernel source tree when the hook fires
#   - .config (if it exists) is at ./.config
#   - The hook is called MULTIPLE times during configure-and-prepare;
#     only one of those calls has .config in place
#   - We must append a representative string to kernel_config_modifying_hashes
#     so Armbian's artifact-versioning sees that the kernel was modified
#   - Use run_kernel_make for make invocations (proper env)
#
# The fragment is expected at userpatches/move.fragment.config (staged
# by the operator; see port/armbian/README.md).

function custom_kernel_config__merge_move_fragment() {
    local fragment="${SRC}/userpatches/move.fragment.config"

    # Only operate on our board
    if [[ "${BOARD}" != "move" ]]; then
        return 0
    fi

    # Always record the fragment in the hash list - even if we skip this
    # specific call - so Armbian's caching recognises the kernel was
    # configured with this fragment in mind.
    if [[ -f "${fragment}" ]]; then
        kernel_config_modifying_hashes+=("move-fragment-$(sha256sum "${fragment}" | cut -c1-12)")
    else
        display_alert "move-kernel-config" \
            "fragment not found at ${fragment}; skipping" "wrn"
        return 0
    fi

    # The hook may be called when .config isn't in place yet (Armbian
    # invokes it multiple times). Bail quietly in that case; we'll be
    # called again later when the kernel source is unpacked and the base
    # config has been copied to .config.
    if [[ ! -f .config ]]; then
        return 0
    fi

    display_alert "move-kernel-config" \
        "merging $(wc -l < "${fragment}") fragment lines into .config" "info"

    # merge_config.sh is in the kernel source tree's scripts/kconfig/.
    # -m: don't run make oldconfig (we'll do it ourselves below)
    # -O .: write the merged output to current directory
    ./scripts/kconfig/merge_config.sh -m -O . .config "${fragment}"

    # Re-resolve any newly-introduced symbol dependencies
    run_kernel_make olddefconfig

    return 0
}
