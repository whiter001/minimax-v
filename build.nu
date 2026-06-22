#!/usr/bin/env nu
# build.nu - Build MiniMax CLI in debug or production mode.
#
# Usage:
#   nu build.nu                 # same as `nu build.nu debug`
#   nu build.nu debug           # debug build: -g, fast compile, full symbols
#   nu build.nu prod            # production build: -prod, -O3 + LTO, stripped
#   nu build.nu --no-vfmt prod  # skip the vfmt formatting check
#   nu build.nu clean           # remove the bin/ directory
#   nu build.nu help            # show this help text
#
# Output:
#   bin/minimax_cli[.exe]   Linux/macOS use `minimax_cli`, Windows uses `.exe`.

# ---------- helpers ----------

const PROJECT_NAME = "minimax-v"
const BINARY_NAME = "minimax_cli"
const OUT_DIR = "bin"
const SOURCE_DIR = "src"

# Print a labelled status line (Nushell-native styling).
def "log info" [msg: string] { print $"(ansi magenta)🔨 ($msg)(ansi reset)" }
def "log ok"   [msg: string] { print $"(ansi green)✅ ($msg)(ansi reset)" }
def "log warn" [msg: string] { print $"(ansi yellow)⚠️  ($msg)(ansi reset)" }
def "log err"  [msg: string] { print $"(ansi red)❌ ($msg)(ansi reset)" }

# Cross-platform V-compiler discovery.
def find-v [] {
    # 1) Respect $V_BIN if the user pointed at a specific binary.
    let cols = ($env | columns)
    if "V_BIN" in $cols {
        let p = ($env.V_BIN | path expand)
        if ($p | path exists) { return $p }
        log warn $"V_BIN=($env.V_BIN) not found, falling back to PATH"
    }

    # 2) Try `v` on $PATH (works on every platform Nushell supports).
    if (which v | length) > 0 {
        return (which v | first | get path | path expand)
    }

    # 3) Common install locations as a last resort.
    let candidates = [
        "/opt/homebrew/bin/v"      # macOS (Apple Silicon)
        "/usr/local/bin/v"         # macOS (Intel) / Linux
        "/usr/bin/v"               # Linux distro package
        $"($env.HOME)/bin/v"
        $"($env.HOME)/.local/bin/v"
        $"($env.HOME)/v/v"
        "C:/v/v.exe"               # Windows default install
        $"($env.USERPROFILE)/v/v.exe"
    ]
    for c in $candidates {
        if ($c | path exists) { return $c }
    }

    log err "V compiler not found. Install from https://vlang.io/ or set V_BIN."
    exit 1
}

# Pretty-print a byte size.
def fmt-size [bytes: int] {
    if $bytes < 1024 { return $"($bytes) B" }
    if $bytes < 1024 * 1024 {
        let kb = $bytes | into float | $in / 1024
        return $"(($kb | math round --precision 1)) KB"
    }
    let mb = $bytes | into float | $in / (1024 * 1024)
    return $"(($mb | math round --precision 2)) MB"
}

# Build with the resolved v-binary and extra flags.
def do-build [v_bin: string, mode: string, extra_flags: list<string>] {
    mkdir $OUT_DIR

    # On Windows V writes `<name>.exe`; elsewhere just `<name>`.
    let is_windows = ((sys host | get name) == "Windows")
    let exe_name = (if $is_windows { $"($BINARY_NAME).exe" } else { $BINARY_NAME })
    let out_path = $"($OUT_DIR)/($exe_name)"

    log info $"Mode: ($mode)"
    log info $"Source: ($SOURCE_DIR)/"
    log info $"Output: ($out_path)"

    let base_flags = if $mode == "prod" {
        ["-prod"]
    } else if $mode == "debug" {
        ["-g"]
    } else {
        log err $"Unknown build mode: ($mode). Use 'debug' or 'prod'."
        exit 1
    }

    let all_flags = ($base_flags | append $extra_flags)
    log info $"Running: ($v_bin) ($all_flags | str join ' ') -o ($out_path) ($SOURCE_DIR)"

    let start = (date now)
    let result = (
        try { ^$v_bin ...$all_flags -o $out_path $SOURCE_DIR | complete }
        catch { |e|
            log err $"Build failed: ($e)"
            exit 1
        }
    )
    if $result.exit_code != 0 {
        log err $"v exited with code ($result.exit_code)"
        log err $result.stderr
        exit 1
    }
    let elapsed = (((date now) - $start) / 1sec)

    if not ($out_path | path exists) {
        log err $"Build reported success but ($out_path) was not produced."
        exit 1
    }

    let size = (ls -la $out_path | first | get size | into int)

    log ok $"Build complete in ($elapsed)s"
    print $"(ansi cyan)   📦  size: (fmt-size $size)(ansi reset)"
    print $"(ansi cyan)   💡  try: ./($out_path) --help(ansi reset)"
}

# Optional formatting gate (mirrors what the nightly CI runs).
def run-vfmt-check [] {
    let script = "tests/check_vfmt.sh"
    if not ($script | path exists) {
        log warn $"($script) not found, skipping format check"
        return
    }
    log info "Running vfmt check..."
    try {
        ^bash $script
        log ok "Formatting OK"
    } catch {
        log err "vfmt check failed; rerun with --no-vfmt to bypass."
        exit 1
    }
}

def show-help [] {
    print $"(ansi bo)(ansi cyan)build.nu — MiniMax CLI build script(ansi rst)"
    print ""
    print "Usage:"
    print "  nu build.nu [debug|prod] [--no-vfmt] [--clean]"
    print "  nu build.nu help"
    print ""
    print "Modes:"
    print "  debug (default)   fast compile, -g, full symbols, useful for stepping"
    print "  prod              -prod, -O3 + LTO, smaller binary, warnings become errors"
    print ""
    print "Options:"
    print "  --no-vfmt         skip the tests/check_vfmt.sh gate"
    print "  --clean           remove bin/ before building"
    print ""
    print "Examples:"
    print "  nu build.nu                # debug build"
    print "  nu build.nu prod           # production build"
    print "  nu build.nu --clean prod   # wipe bin/ then build prod"
    print "  nu build.nu clean          # just remove bin/"
}

# ---------- entrypoint ----------

def main [
    mode: string = "debug"    # build mode: debug | prod | clean | help
    --no-vfmt                  # skip the formatting check before building
    --clean                    # delete bin/ before building
] {
    if $mode == "help" or $mode == "-h" or $mode == "--help" {
        show-help
        return
    }

    if $mode == "clean" {
        if ($OUT_DIR | path exists) {
            rm -rf $OUT_DIR
            log ok $"Removed ($OUT_DIR)/"
        } else {
            log warn $"($OUT_DIR)/ does not exist, nothing to clean"
        }
        return
    }

    if $mode not-in ["debug", "prod"] {
        log err $"Unknown mode: ($mode). Run `nu build.nu help` for usage."
        exit 1
    }

    let v_bin = (find-v)
    log info $"Using V compiler: ($v_bin)"

    if $clean {
        if ($OUT_DIR | path exists) { rm -rf $OUT_DIR }
        log ok $"Cleaned ($OUT_DIR)/"
    }

    if not $no_vfmt {
        run-vfmt-check
    } else {
        log warn "Skipping vfmt check (--no-vfmt)"
    }

    do-build $v_bin $mode []
}
