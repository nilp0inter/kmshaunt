# kmscon 10.1.0 — authoritative option reference

Complete option reference for the kmscon 10.1.0 option surface, extracted from
source, for kmshaunt's M2/M6/M7 parity work and the ROADMAP appendix parity
matrix. Every option that kmscon's config parser recognizes is listed here;
defaults, grab combinations and format strings are copied from source, not
inferred from man pages.

## 0. Provenance and pins

| Item | Value | Where verified |
|---|---|---|
| kmscon version | 10.1.0 | `meson.build:7` (`project('kmscon', 'c', version: '10.1.0', …)`) |
| Source used | nixpkgs `kmscon.src` = upstream GitHub tag `v10.1.0` tarball (`https://github.com/kmscon/kmscon/archive/refs/tags/v10.1.0.tar.gz`) | `nix eval nixpkgs#kmscon.src.url` |
| Palette presets (`--palette`) | libtsm **v4.8.0** (kmscon wraps `tsm_vte_set_palette`, `tsm_vte_set_custom_palette`) | `subprojects/libtsm.wrap` (revision `v4.8.0`); nixpkgs has libtsm 4.8.0 |
| Compile-time defaults | `BUILD_CONFIG_DIR = prefix/sysconfdir` = `<prefix>/etc/kmscon`; `BUILD_DEFAULT_TERM = <meson option 'term'>` (default `kmscon`) | `meson.build:153-159`, `meson.options:52` |

Citation convention: `src/config.c:1055` etc. are paths inside the kmscon
10.1.0 source tree; `tsm-vte.c:410` is inside libtsm 4.8.0
(`src/tsm/tsm-vte.c` downstream).

The single authoritative option table is `kmscon_conf_new()` in
`src/config.c:981-1088`. The parser that gives the options meaning is
`src/misc/conf.c` (argv: 173-313, file: 317-537, types: 550-1108).

---

## 1. Master table — every option in config.c

Legend: type is the `conf_*` type used by the option (bool, uint, string) or
the kmscon-custom type (vt, login, gpus, modes, screens, color, grab).
`no-` negation applies only to bool options (both CLI and file). "repeatable"
options may appear multiple times; later values append (mode/screen) or
replace (all others — "only the last argument matters" per the help text,
`src/config.c:65-66`).

| Option | Type | Default | Milestone-relevant notes |
|---|---|---|---|
| `-h`, `--help` | bool | off | aftercheck prints help and sets exit (`config.c:844-846`) |
| `-V`, `--version` | bool | off | aftercheck prints version; with `--verbose` also build info (`config.c:854-881`) |
| `-v`, `--verbose` | bool | off | log level INFO (`config.c:1132-1135`) |
| `--debug` | bool | off | implies verbose (`config.c:827-835`, `aftercheck_debug`); log level DEBUG |
| `--silent` | bool | off | log level WARNING, suppresses notices/warnings |
| `-c`, `--configdir` | string | `BUILD_CONFIG_DIR` = `/etc/kmscon` (standard `--prefix=/usr`) | `CONF_OPTION_STRING('c', "configdir", …, BUILD_CONFIG_DIR)` `config.c:989`; file is `<dir>/kmscon.conf` |
| `--vt` | vt (string-ish) | NULL → auto-detect | integer → `/dev/ttyN`; `ttyX` → `/dev/ttyX`; `.`/`/`-prefixed → taken verbatim (`config.c:340-372`) |
| `--switchvt` | bool | **on** | activate VT at startup / restore previous VT at exit (`seat.c:831-833`, `1060-1061`) |
| `--libseat` | bool | **off** | `uterm_vt_allocate(..., conf->libseat, ...)` `seat.c:703`; compile-gated by meson `libseat` option |
| `--session-max` | uint | 50 | 0 = no limit (`seat.c:1085-1089`) |
| `--session-control` | bool | off | enables session grabs; auto-disabled on real VTs (`seat.c:780-784`) |
| `--issue` | bool | **on** | `--no-issue` lets login handle it; issue buffer written on terminal open (`terminal.c:1291`, `1315-1317`) |
| `--issue-path` | string | `/etc/issue:/etc/issue.d:/run/issue:/run/issue.d:/usr/lib/issue:/usr/lib/issue.d` | `ISSUE_DEFAULT_PATH`, `misc/issue.h:20-24`; colon-separated files+dirs (`*.issue`) |
| `--asciicast` | string | unset (NULL) | path to asciicast v2/v3 file; stopped on keyboard input (`terminal.c:972`, `1522-1527`) |
| `--asciicast-loop` | bool | off | loop the playback (`asciinema.c` `player->loop`) |
| `-l`, `--login` | login (bool+argv) | off; argv `/bin/login -p` | CLI: consumes **all** remaining argv after `--` (`config.c:392-419`); file: `arg` shell-split (`config.c:422-454`) |
| `--oneshot` | bool | off | exit kmscon when login process exits (passed to pty, `terminal.c:1492-1494`) |
| `-t`, `--term` | string | `BUILD_DEFAULT_TERM` = `kmscon` | sets child `$TERM`; distros may compile a different default |
| `--reset-env` | bool | **on** | child gets empty env, then TERM/COLORTERM/XDG_SEAT/XDG_VTNR/… (`misc/pty.c:205-221`) |
| `--backspace-delete` | bool | **on** | `tsm_vte_set_backspace_sends_delete` (`terminal.c:1464`) |
| `--sb-size` | uint | 1000 | scrollback lines; `tsm_screen_set_max_sb` (`terminal.c:1458`) |
| `--bell` | bool | off | BEL (0x07) forwarded to VT (`terminal.c:507-510`) |
| `--blink` | bool | **on** | cursor + text blink timers (`terminal.c:1348-1351`, `1364-1367`, `1512-1521`) |
| `--xkb-model` | string | unset | `xkb_model`; unset → locale1 (sd-bus) / xkb default |
| `--xkb-layout` | string | unset | e.g. `de` |
| `--xkb-variant` | string | unset | |
| `--xkb-options` | string | unset | |
| `--xkb-keymap` | string | unset | predefined keymap file; takes precedence over model/layout/variant/options; empty string = none (`input_set_keymap` `seat.c:737-739`) |
| `--xkb-compose-file` | string | unset | compose file; locale from `LC_ALL`/`LC_CTYPE`/`LANG`, fallback `C` (`seat.c:612`, `743`) |
| `--xkb-repeat-delay` | uint | 250 | ms, initial repeat delay (`input_set_conf` `seat.c:734-735`) |
| `--xkb-repeat-rate` | uint | 50 | ms between repeats |
| `--mouse` | bool | **on** | pointer capture + selection/copy-paste + wheel scroll (`input_set_conf`, `terminal.c:1068-1070`) |
| `--natural-scrolling` | bool | off | inverts wheel (`terminal.c:1069-1070`, `1235-1238`) |
| `--soft-cursor` | bool | off | force software cursor (`terminal.c:872`) |
| `--dpms-timeout` | uint | 600 | **seconds**; 0 = disabled (`seat.c:462-463`, `767-777`) |
| `--grab-scroll-up` | grab | **Shift+Up** | scroll back 1 line (`terminal.c:976-981`) |
| `--grab-scroll-down` | grab | **Shift+Down** | scroll forward 1 line |
| `--grab-page-up` | grab | **Shift+Prior** (PageUp) | scroll back 1 page |
| `--grab-page-down` | grab | **Shift+Next** (PageDown) | scroll forward 1 page |
| `--grab-zoom-in` | grab | **Ctrl+plus and Ctrl+equal** (two-keysym grab) | `zoom_in` (`terminal.c:1000-1004`) |
| `--grab-zoom-out` | grab | **Ctrl+minus** | `zoom_out` |
| `--grab-session-next` | grab | **Ctrl+Logo+Right** | needs `session-control`, ≥2 sessions (`seat.c:537-543`) |
| `--grab-session-prev` | grab | **Ctrl+Logo+Left** | |
| `--grab-session-close` | grab | **Ctrl+Logo+BackSpace** | |
| `--grab-terminal-new` | grab | **Ctrl+Logo+Return** | needs `session-control` |
| `--grab-rotate-cw` | grab | **Logo+plus and Logo+equal** (two-keysym grab) | `rotate_cw_all` (`terminal.c:1010-1014`) |
| `--grab-rotate-ccw` | grab | **Logo+minus** | |
| `--grab-reboot` | grab | **none — disabled** | default `NULL` (`config.c:1048`); soft/hard reboot per `/proc/sys/kernel/ctrl-alt-del` (`seat.c:421-455`) |
| `--drm` | bool | **on** | if built without DRM2D+DRM3D, forced off (`config.c:889-915`); selects DRM devices over fbdev, `hwaccel` → drm3d (`seat.c:864-867`, `906-929`) |
| `--hwaccel` | bool | off | drm3d backend; auto-fallback to drm2d on failure (`seat.c:923-928`) |
| `--gpus` | gpus (enum) | `all` | accepts `all`, `aux`/`auxiliary`, `primary`/`single` (`config.c:466-498`) |
| `--use-original-mode` | bool | off | skip modesetting, keep current KMS mode (`seat.c:922`, `drm_shared.c:1377-1378`); **incompatible with `--mode`** — with both set, kmscon logs an error and clears `use-original-mode` (`config.c:1158-1165`) |
| `--mode` | modes (repeatable list) | none | `[gpu][connector]WxH@rate`; see §5.3 |
| `--multi-monitor` | string | `scaled` | `clone`\|`largest`\|`scaled`; any other value → clone behavior (`terminal.c:752-757`); **absent from `--help` output** |
| `--screen` | screens (repeatable list) | none | `[gpu][connector]normal|left|right|upside-down|disabled`; see §5.4 |
| `--font-engine` | string | unset → fallback chain `freetype, pango, unifont, psf, 8x16` | `font/font.c:219` `default_backend[]`; unknown engine → chain, then first registered backend |
| `--font-size` | uint | 0 | pixels, 0 = auto (`terminal.c:1479-1490`) |
| `--font-name` | string | `monospace` | fontconfig pattern (freetype/pango); path for psf |
| `--palette` | string | unset (NULL) → libtsm **legacy** palette | preset names in libtsm 4.8.0: `custom`, `nord`, `solarized`, `solarized-black`, `solarized-white`, `soft-black`, `base16-dark`, `base16-light`, `vga`, `legacy`; unknown name → legacy (`tsm-vte.c:410-431`). `nord` is **not in the roadmap appendix** |
| `--palette-black` | color | 0,0,0 | custom-palette slot; value `R,G,B` 0..255 (`config.c:770-822`; defaults `config.c:945-967`) |
| `--palette-red` | color | 205,0,0 | |
| `--palette-green` | color | 0,205,0 | |
| `--palette-yellow` | color | 205,205,0 | |
| `--palette-blue` | color | 0,0,238 | |
| `--palette-magenta` | color | 205,0,205 | |
| `--palette-cyan` | color | 0,205,205 | |
| `--palette-light-grey` | color | 229,229,229 | |
| `--palette-dark-grey` | color | 127,127,127 | |
| `--palette-light-red` | color | 255,0,0 | |
| `--palette-light-green` | color | 0,255,0 | |
| `--palette-light-yellow` | color | 255,255,0 | |
| `--palette-light-blue` | color | 92,92,255 | |
| `--palette-light-magenta` | color | 255,0,255 | |
| `--palette-light-cyan` | color | 0,255,255 | |
| `--palette-white` | color | 255,255,255 | |
| `--palette-foreground` | color | 229,229,229 | `TSM_COLOR_FOREGROUND` slot |
| `--palette-background` | color | 0,0,0 | `TSM_COLOR_BACKGROUND` slot |

Total: 77 options — 6 global + 3 seat + 2 session + 12 terminal + 12 input +
13 grabs + 7 video + 3 font + 1 `palette` + 18 `palette-*` colors (16 ANSI +
foreground + background; `TSM_COLOR_NUM` slots).

### Not in the roadmap appendix (present in source)

Nothing in `src/config.c` is missing from the ROADMAP appendix table; the
appendix's `palette-*` covers the 18 color options. Two facts the appendix
does not state:

1. **`--palette=nord`** is a valid preset (libtsm 4.8.0 added `nord`,
   `tsm-vte.c:415-416`) — the appendix palette list omits it.
2. **`--multi-monitor`** exists (default `scaled`) but is **not printed by
   `--help`** (`print_help` lists only drm/hwaccel/gpus/use-original-mode/
   mode/screen under Video Options, `config.c:255-284`).

Also note the ROADMAP mentions `screen=` for "rotation and disable per
connector" and `grab-rotate-*` — those map to the `--screen` orientations
(`normal`, `left`, `right`, `upside-down`; `disabled`) and the rotate grabs.

---

## 2. CLI parsing rules

Implemented with `getopt_long` (`src/misc/conf.c:173-313`).

- Short options: `-h`, `-V`, `-v`, `-c`, `-l`, `-t`. `-c`/`-t` take arguments.
- Long options take arguments **only when `=` is used or the value is the next
  argv element** (`optarg` semantics). `--flag value` and `--flag=value` are
  equivalent; kmscon's own help examples use both (`--xkb-layout=de`).
- **Boolean negation**: every bool option is also registered as `no-<name>`
  (`CONF_OPTION` macro stores `long_name = "no-" _long`, `misc/conf.h:168-169`;
  argv parser maps `NO_LONG_OPTION` → `parse(..., false, NULL)`,
  `misc/conf.c:303-311`). So `--no-switchvt`, `--no-issue`, `--no-libseat`,
  `--no-use-original-mode`, … are valid. On the **CLI**, `no-` exists only for
  no-arg (bool) types; argument-taking options reject it (getopt "option takes
  no argument"). In the **config file**, `no-<name>` keys are recognized for
  every option (the internal `long_name` always carries the prefix), but the
  negation merely sets `on=false` — every non-bool parser in kmscon ignores
  `on` and parses the value anyway, so `no-` is only meaningful for booleans.
- **Last one wins**: repeated options overwrite earlier values (except `mode`
  and `screen`, which append). Help text: "If an argument is given multiple
  times, only the last argument matters if not otherwise stated"
  (`config.c:65-66`).
- **Unknown/invalid CLI options are ignored with a warning**, not fatal:
  `conf_ctx_parse_argv` continues and `kmscon_conf_load_main` logs
  "Some wrong command line arguments ignored: %d". A failed parse leaves the
  option at its previous value (`misc/conf.c:283-287`).
- After parsing, each option's `aftercheck` runs in table order; `--login`
  consumes all remaining argv (`aftercheck_login` `config.c:392-419`), then
  any leftover argv is an error ("Unparsed remaining args starting with: …").
- `-l` / `--login`: everything **after** the first `--` is the login argv, and
  nothing after `--` is parsed as an option. `--login` with no following args
  is an error ("Arguments for --login missing").

## 3. Config file rules

Parsed by `conf_ctx_parse_file` → `conf_parse_file` → `parse_buffer` →
`parse_line` (`src/misc/conf.c:373-537`). The file is parsed **as if the
key/value pairs were command-line options**, with these exact syntax rules:

- **Line format**: `key` or `key=value`. A line without `=` is a bare boolean
  (`key` = true; `no-key` in the file negates, matching the CLI's `no-`
  prefix — `parse_kv_pair` `misc/conf.c:330-337`).
- **`#` starts a comment** — everything from `#` to end of line is dropped
  (in key and in value). Example `### General Options ###` lines are pure
  comments.
- **Whitespace**: leading/trailing spaces, `\r`, `\t` are stripped from key
  and value (`strip_spaces`), so `key = value` works. Interior whitespace in
  values is preserved.
- **Overflow**: a key running to end of file without `\n`/`#`/`=` is an error;
  a `=` with no value gives an empty value.
- **Errors are fatal for the file**: unknown keys log an error but are
  skipped (`-EAGAIN`), but a value-taking key without a value, a no-arg key
  with a value, an unparseable `mode`/`screen`/color/grab/etc., or a missing
  value for `login` **aborts the whole config load** (`config.c:1136-1138`
  propagates the error; main logs "cannot load configuration: %d").
- **File is optional**: if `<configdir>/kmscon.conf` does not exist, parsing
  silently succeeds (`misc/conf.c:493-496`). If it exists but is unreadable →
  error `-EACCES`.
- **List-ish values** need no quoting: `issue-path` is a colon list,
  `xkb-options` comma list (passed through as one string to xkbcommon),
  `mode`/`screen` are repeatable lines (one per line), the 18 `palette-*`
  colors are `r, g, b` triples (spaces allowed after commas, e.g.
  `palette-foreground=255, 0, 0`).
- **`login` in a file** is special: the value is split into argv with POSIX
  shell-like rules (`shl_split_command_string`, `config.c:422-454`) — quoting
  with `'…'`/`"…"` or `\ ` includes spaces in one argument. e.g.
  `login=/bin/bash -i`.
- **Booleans take no value**: `mouse=1` is an error ("does not take
  arguments"); write `mouse` or `no-mouse`.

### Precedence

1. Defaults (static per-option defaults).
2. Command line — parsed first; every parsed option is marked `CONF_LOCKED`
   (`misc/conf.c:283`, `309-311`), so the config file **cannot override a
   CLI-set option** (`parse_kv_pair` skips locked entries, `misc/conf.c:336-338`).
3. `<configdir>/kmscon.conf`.
4. `<configdir>/<seat>.seat.conf` — parsed per seat in
   `kmscon_conf_load_seat` (`config.c:1167-1185`): the seat context is copied
   from the main context (`conf_ctx_parse_ctx`, preserving locked flags) and
   the seat file is layered on top, so it overrides the main file but not CLI
   options.

### Environ interactions

- `--term`: sets child `$TERM` (pty default `vt220` if unset, `misc/pty.c:223`).
- On every session: `COLORTERM=truecolor`, `XDG_SEAT=<seat>`,
  `XDG_VTNR=<vt>`, `TERM_SESSION_TYPE=kms` (DRM) or `fb` (fbdev), and
  `KMS_START_SCRIPT=kmscon-launch-gui` (DRM only) (`misc/pty.c:230-244`).
- `--reset-env` (default on): the child starts with a **completely empty
  environment** (`environ = env` with no entries) before the above are set.
  When off, the parent's environment is inherited and the login default argv
  becomes `/bin/login` (no `-p`) (`misc/pty.c:205-219`).
- locale1: unless any of `xkb-keymap/model/layout/variant/options` is set,
  kmscon reads `org.freedesktop.locale1` `X11Layout`/`X11Variant`/`X11Options`
  at start and follows it live over sd-bus, recompiling the keymap
  (`main.c:104-121`, `misc/dbus.c`).

## 4. Config file discovery

- `--configdir` default: `BUILD_CONFIG_DIR` = `prefix + sysconfdir` where
  `sysconfdir = <sysconfdir option>/kmscon` (`meson.build:39`, `156`). With the
  standard `--prefix=/usr`, that is **`/etc/kmscon`**; the man pages render it
  as `@CONFIG_DIR@` = `/etc/kmscon`.
- Main file: `%s/kmscon.conf` (`config.c:1136`).
- Per-seat file: `%s/%s.seat.conf` (`config.c:1182`) where `%s` is the seat
  name from the VT backend: `libseat_seat_name()` under libseat (usually
  `seat0`), else `"seat0"` fallback (`uterm/vt.c:207-211`). So default files
  are `/etc/kmscon/kmscon.conf` and `/etc/kmscon/seat0.seat.conf`.
  ⚠️ The man pages (`kmscon.1.xml.in`) document the seat file as
  `{seat_name}.kmscon.conf` — **that name is stale; the source uses
  `{seat}.seat.conf`**.
- Seat configuration is copied from the main context on top of defaults, then
  the seat file applies (see precedence, §3).

## 5. Per-group detail

### 5.1 Seat (`src/seat.c`, `src/uterm/`)

- **`--vt`** — custom string type (`config.c:340-372`):
  - numeric (`shl_strtou` success) → `/dev/ttyN`;
  - starts with `.` or `/` → used verbatim (path to arbitrary tty device);
  - anything else → prefixed with `/dev/` (e.g. `tty2` → `/dev/tty2`);
  - unset → `seat_find_vt()`: controlling tty, else a free `/dev/ttyN`
    (`uterm/vt_real.c:617-675`); on VTs-less seats a fake VT is used.
- **`--switchvt`** (default on): activate the VT at startup; at exit, if set,
  `uterm_vt_deactivate` restores the previously active VT and main waits up to
  100 ms for the SIGUSR2 ack (`seat.c:831-833`, `main.c:167-170`).
- **`--libseat`** (default off): pass `libseat=true` to
  `uterm_vt_allocate` (`seat.c:703`); with libseat the vt backend is
  `vt_libseat` (seatd/logind seat, device open via the seat manager), else
  `vt_real` (open VT + DRM master) (`uterm/vt.c:81-85`).
- **`--session-max`** (default 50, 0 = unlimited): cap checked when a new
  session is created (`seat.c:1085-1089`).
- **`--session-control`**: gates the four session grabs
  (`seat.c:537-571`); on exits with `uterm_vt_get_num(seat->vt) > 0` (real
  VT) it is force-disabled with a warning (`seat.c:780-784`).

### 5.2 Terminal (`src/terminal.c`, `src/misc/`)

- **`--sb-size`** (default 1000): `tsm_screen_set_max_sb` — scrollback is
  capped at N lines (`terminal.c:1458`).
- **`--bell`**: when off, BEL from the app is dropped; when on it is
  forwarded to the VT via `uterm_vt_bell` (`terminal.c:507-510`,
  `seat.c:1212-1218`).
- **`--blink`** (default on): drives the blink timers for the cursor and
  blinking-text attributes (`terminal.c:1348-1351` fg, `1512-1521` setup,
  `1364-1367` bg).
- **`--backspace-delete`** (default on): `tsm_vte_set_backspace_sends_delete`
  (libtsm handles BS vs DEL when on) plus the pty's termios erase handling
  (`terminal.c:1464`, `misc/pty.c:264`).
- **`--issue` / `--issue-path`**: on terminal open, `kmscon_issue_get_buffer`
  collects and expands the issue text, then writes it to the pty before login
  (`terminal.c:1291-1317`). Collection: files read directly, directories
  scanned for `*.issue` in lexicographic order, total capped at 256 KiB,
  same-basename files masked so the first in path order wins
  (`issue.c:129-212` files/dirs, `214+` collection, `ISSUE_MAX_SIZE` at
  `issue.c:41`). Expansion escapes in §5.5.
- **`--asciicast <path>` / `--asciicast-loop`**: plays an asciicast file into
  the pty after open; stopped on first keyboard input (`terminal.c:972`,
  `1522-1527`). Format in §5.6.
- **`--login` / `--oneshot` / `--term` / `--reset-env`**: pty child config
  (`terminal.c:1492-1494` → `misc/pty.c:180-250`). `oneshot` is passed to the
  pty; when the child exits and `oneshot` is set, the terminal destroys the
  session and (being the only session) kmscon exits — used for setup scripts /
  disk-encryption prompts (help text `config.c:86-97`).
- **`--font-size`** (0 = auto): fixed size tries `font_set(term, size)`; on
  failure falls back to 16 px (width retry), then auto (`terminal.c:558-566`,
  `1479-1490`).

### 5.3 `--mode` syntax (`config.c:519-609`)

Repeatable. Grammar (all three `sscanf` attempts in order):

```
gpu[connector]WxH@R     e.g. card0[HDMI-A-1]1920x1080@60
[connector]WxH@R        e.g. [HDMI-A-1]1920x1080@60
WxH@R                   e.g. 1920x1080@60
```

- `W` and `H` required and must be non-zero, else `-EINVAL` (option ignored
  on CLI, fatal in file).
- `R` (rate) optional; `gpu` and `connector` limited to 63 chars
  (`MAX_DISPLAY_NAME_LEN 64`, `config.h:49`).
- Lookup at display setup (`config_get_mode`, `config.c:580-609`): first match
  wins — (1) exact gpu+connector, (2) connector only, (3) globals (no
  gpu/connector). No match → default mode (first valid) is used
  (`drm_shared.c:1364-1388`).
- Only effective for DRM devices; fbdev ignores it (fbset does the job
  externally). If `--mode` is used together with `--use-original-mode`, kmscon
  logs "Cannot use --mode if --use-original-mode is enabled. Try
  --no-use-original-mode." and clears `use-original-mode` (`config.c:1158-1165`).

### 5.4 `--screen` syntax (`config.c:627-750`)

Repeatable. Grammar: `[gpu][connector]config` where `config` is one of
`normal`, `left`, `right`, `upside-down`, `disabled` (anything else →
`-EINVAL`):

```
gpu[connector]normal     e.g. card0[DP-1]right
[connector]left          e.g. [HDMI-A-1]left
disabled                 applies to all displays
upside-down
```

- Matching identical precedence to `mode` (gpu+connector → connector →
  global) via `config_get_screen` (`config.c:710-750`); unmatched displays
  fall back to `OR_NORMAL`, enabled.
- `disabled` = kmscon won't use that display (unless it is the only available
  display — see `kmscon.1.xml.in` `--screen` entry). Per-display orientation
  is fed to the text renderer (`terminal.c:849-851`).

### 5.5 Issue escape set (`misc/issue.c:459-537`)

agetty-style `\` escapes inside issue text (a `\n` in the file is **nodename,
not newline** — literal newlines in files are emitted as `\r\n` so the
terminal renders them correctly, `issue.c:367-374`).

| Escape | Expansion |
|---|---|
| `\\` | literal backslash |
| `\s` | `uname().sysname` |
| `\n` | `uname().nodename` |
| `\r` | `uname().release` |
| `\v` | `uname().version` |
| `\m` | `uname().machine` |
| `\o` | `uname().domainname`, `(none)` if empty |
| `\d` | local date `%Y-%m-%d` |
| `\t` | local time `%H:%M:%S` |
| `\l` | pty name (slave tty name, e.g. `tty1`) |
| `\S{field}` | `/etc/os-release` (fallback `/usr/lib/os-release`) `field`; no `{…}` → `PRETTY_NAME`; quoted values unquoted (`issue.c:75-114`, `282-296`) |
| `\e{name}` | SGR: emits `ESC` + sequence for color/bold name (`issue.c:369-382`) |
| `\4{iface}` | best IPv4 address of interface |
| `\6{iface}` | best IPv6 address of interface |
| `\a` | all local IPv4 addresses, filtered |
| `\A` | all local addresses, unfiltered |
| anything else | dropped silently |

The escape switch itself is `issue.c:459-537`. `\e` color names
(`color_sequence_from_colorname`, `issue.c:333-367`):
`black`, `red`, `green`, `brown`, `blue`, `magenta`, `cyan`, `gray`,
`darkgray`, `lightred`, `lightgreen`, `yellow`, `lightblue`,
`lightmagenta`, `lightcyan`, `white`, `bold`, `halfbright`,
`blink`, `reverse`, `reset`. (There is **no** `underscore` entry —
util-linux's issue has one, kmscon's table does not — and `lightgray`
maps to `[37m`.) Issued SGR sequences: `reset=[0m`, `bold=[1m`,
`halfbright=[2m`, `blink=[5m`, `reverse=[7m`, standard colors
`[30m`-`[37m`, bold variants `[1;30m`-`[1;37m` (`issue.c:44-62`).

### 5.6 Asciicast format (`misc/asciinema.c`)

- File is line-delimited JSON events, **v2 or v3** (header line must contain
  `"version"`; other versions → error).
- Only **output events** (`["code"="o"]`) are played; input/marker/resize
  events are ignored (`parse_event_line`).
- v2: event `t` is absolute output time; delays are differences (`t -
  last_output_time`, clipped at 0).
- v3: `t` is delta time accumulated until the next `o` event (non-`o`
  events add their `t` to a pending interval); `#` comment lines (starting
  with `#` as first char) are skipped.
- Single `"data"` string content is written to the pty as-is.
- Hard limits: 256 KiB max line, 2 MiB total output, 16384 events, timer
  clamp to 1 s per event (min tick 1 ms). A file with no output events →
  error. `loop` restarts from event 0 when exhausted.

### 5.7 Grabs — syntax and default bindings

Syntax (`misc/conf.c:838-911` `parse_single_grab`, `916-1050` `conf_parse_grab`): a comma-separated list of shortcuts; each
shortcut is `mod*key` tokens joined by `+`:

```
grab-terminal-new=<Ctrl><Logo>Return
grab-reboot=<Ctrl><Alt>Delete
grab-scroll-up=<Shift>Up,<Ctrl>u          # two shortcuts for one action
grab-page-up=<Shift>H+E+L+L+O             # multi-keysym key match
grab-zoom-in=                             # empty → disabled
```

- Modifiers (`<shift>`, `<lock>` (Caps), `<control>`/`<ctrl>`, `<alt>`,
  `<logo>`) are case-insensitive, must appear in the **first** token;
  unknown modifier → error (`parse_single_grab`).
- The key is a **case-sensitive xkb keysym name**; wrong case yields a
  suggestion and an error (`misc/conf.c:900-911` — the error aborts the
  option; on CLI the option is ignored, in file the load fails).
- Multi-keysym keys: `H+E+L+L+O` matches a key producing exactly those
  keysyms; it does **not** require pressing H, E, L, O together.
- Empty argument or a shortcut with no key → that grab matches nothing
  (disabled).
- Match semantics (`grab_matches`/`conf_grab_matches`, `misc/conf.c:1081-1108`):
  the event's modifier state must **exactly equal** the grab's modifiers — the
  mask is five bits, shift/lock(caps)/ctrl/alt/logo (`shl/misc.h:509-531`,
  `shl_get_xkb_mods`), so holding any extra modifier of those five breaks the
  match. Keysyms must match exactly in count and value.
- Grabs are **not** `no-`-negatable (they take an argument; negation concept
  = empty value).

Source-of-truth default bindings — `src/config.c:915-943`:

| Grab | Default (source) | Notes |
|---|---|---|
| `grab-scroll-up` | `CONF_SINGLE_GRAB(SHL_SHIFT_MASK, XKB_KEY_Up)` → Shift+Up | |
| `grab-scroll-down` | `CONF_SINGLE_GRAB(SHL_SHIFT_MASK, XKB_KEY_Down)` → Shift+Down | |
| `grab-page-up` | `CONF_SINGLE_GRAB(SHL_SHIFT_MASK, XKB_KEY_Prior)` → Shift+Prior | Prior = Page Up |
| `grab-page-down` | `CONF_SINGLE_GRAB(SHL_SHIFT_MASK, XKB_KEY_Next)` → Shift+Next | Next = Page Down |
| `grab-zoom-in` | `CONF_DUAL_GRAB(SHL_CONTROL_MASK, XKB_KEY_plus, XKB_KEY_equal)` → Ctrl+plus **or** Ctrl+equal | two-keysym grab |
| `grab-zoom-out` | `CONF_SINGLE_GRAB(SHL_CONTROL_MASK, XKB_KEY_minus)` → Ctrl+minus | |
| `grab-session-next` | `CONF_SINGLE_GRAB(SHL_CONTROL_MASK\|SHL_LOGO_MASK, XKB_KEY_Right)` → Ctrl+Logo+Right | needs `session-control` |
| `grab-session-prev` | `… XKB_KEY_Left` → Ctrl+Logo+Left | |
| `grab-session-close` | `… XKB_KEY_BackSpace` → Ctrl+Logo+BackSpace | |
| `grab-terminal-new` | `… XKB_KEY_Return` → Ctrl+Logo+Return | |
| `grab-rotate-cw` | `CONF_DUAL_GRAB(SHL_LOGO_MASK, XKB_KEY_plus, XKB_KEY_equal)` → Logo+plus **or** Logo+equal | two-keysym grab |
| `grab-rotate-ccw` | `CONF_SINGLE_GRAB(SHL_LOGO_MASK, XKB_KEY_minus)` → Logo+minus | |
| `grab-reboot` | `NULL` (no default binding) | disabled unless configured; follows `/proc/sys/kernel/ctrl-alt-del` (`seat.c:421-455`) |

### 5.8 Video (`src/video/`, `seat.c`)

- `--gpus` filtering in `kmscon_seat_gpu_is_ignored` (`seat.c:876-885`):
  `primary` → only `UTERM_MONITOR_PRIMARY` devices; `aux` → primary + aux.
  Flags come from udev: `is_drm_primary`/`is_drm_usb`
  (`uterm/monitor.c:343-346`).
- `--drm` on: fbdev devices that are DRM-backed are ignored, DRM devices used;
  `--no-drm`: DRM devices ignored, plain fbdev used (`seat.c:853-868`).
- `--hwaccel` selects the drm3d backend; on creation failure kmscon falls
  back to drm2d automatically (`seat.c:923-928`).
- `--multi-monitor` (`terminal.c:752-757`): `largest` → the largest monitor
  sets cols/rows and others are disabled; `scaled` → smallest monitor sets
  cols/rows, larger monitors scale the font up (`terminal.c:728-750`); default
  `scaled`; anything else (incl. `clone`) → all monitors same size, smallest
  determines it.
- `--dpms-timeout` (seconds, 0 = off): inactivity timer per seat; on expiry
  the display is blanked (DPMS off); any input unblanks and resets the timer
  (`seat.c:456-513`, `767-777`).

### 5.9 Font (`src/font/`)

- `--font-engine` selects a registered backend by name; registered backends:
  `freetype`, `pango`, `unifont`, `psf`, `8x16` (module names from
  `font/mod_*.c` and the built-in `kmscon_font_8x16_ops`). If unset or the
  requested engine is unavailable, the fallback chain is tried in order
  `freetype → pango → unifont → psf → 8x16` (`default_backend[]`
  `font/font.c:219`); last resort: first registered backend.
- `--font-name` is a fontconfig family/pattern for freetype/pango, or a file
  path for the `psf` engine. `--font-size` in pixels, 0 = auto-detect from
  connector physical size (`terminal.c` `terminal_get_auto_font_size`).

### 5.10 Palette presets (libtsm 4.8.0, `tsm-vte.c:214-408`)

`--palette` names, resolved by `get_palette` (`tsm-vte.c:410-431`):
`custom` (→ the 18 `--palette-*` colors), `nord`, `solarized`,
`solarized-black`, `solarized-white`, `soft-black`, `base16-dark`,
`base16-light`, `vga`, `legacy`. **Unset or unknown → legacy.** `nord` is
new in libtsm 4.8.0 and missing from the ROADMAP appendix.

kmscon's `def_palette` (the `custom` default, `config.c:945-967`) is
byte-for-byte a copy of `legacy`.

Full RGB tables (each row: 16 ANSI colors, then foreground/background):

| color | legacy (=custom default) | vga | nord | solarized | solarized-black | solarized-white | soft-black | base16-dark | base16-light |
|---|---|---|---|---|---|---|---|---|---|
| black | 0,0,0 | 0,0,0 | 59,66,82 | 7,54,66 | 0,0,0 | 7,54,66 | 3f,3f,3f | 00,00,00 | 00,00,00 |
| red | 205,0,0 | 170,0,0 | 191,97,106 | 220,50,47 | 220,50,47 | 220,50,47 | 70,50,50 | ab,46,42 | ab,46,42 |
| green | 0,205,0 | 0,170,0 | 163,190,140 | 133,153,0 | 133,153,0 | 133,153,0 | 60,b4,8a | a1,b5,6c | a1,b5,6c |
| yellow | 205,205,0 | 170,85,0 | 235,203,139 | 181,137,0 | 181,137,0 | 181,137,0 | df,af,8f | f7,ca,88 | f7,ca,88 |
| blue | 0,0,238 | 0,0,170 | 129,161,193 | 38,139,210 | 38,139,210 | 38,139,210 | 9a,b8,d7 | 7c,af,c2 | 7c,af,c2 |
| magenta | 205,0,205 | 170,0,170 | 180,142,173 | 211,54,130 | 211,54,130 | 211,54,130 | dc,8c,c3 | ba,8b,af | ba,8b,af |
| cyan | 0,205,205 | 0,170,170 | 136,192,208 | 42,161,152 | 42,161,152 | 42,161,152 | 8c,d0,d3 | 86,c1,b9 | 86,c1,b9 |
| light grey | 229,229,229 | 170,170,170 | 229,233,240 | 238,232,213 | 238,232,213 | 238,232,213 | ff,ff,ff | aa,aa,aa | aa,aa,aa |
| dark grey | 127,127,127 | 85,85,85 | 76,86,106 | 0,43,54 | 0,43,54 | 0,43,54 | 70,90,80 | 55,55,55 | 55,55,55 |
| light red | 255,0,0 | 255,85,85 | 191,97,106 | 203,75,22 | 203,75,22 | 203,75,22 | dc,a3,a3 | ab,46,42 | ab,46,42 |
| light green | 0,255,0 | 85,255,85 | 163,190,140 | 88,110,117 | 88,110,117 | 88,110,117 | 72,d5,a3 | a1,b5,6c | a1,b5,6c |
| light yellow | 255,255,0 | 255,255,85 | 235,203,139 | 101,123,131 | 101,123,131 | 101,123,131 | f0,df,af | f7,ca,88 | f7,ca,88 |
| light blue | 92,92,255 | 85,85,255 | 129,161,193 | 131,148,150 | 131,148,150 | 131,148,150 | 94,bf,f3 | 7c,af,c2 | 7c,af,c2 |
| light magenta | 255,0,255 | 255,85,255 | 180,142,173 | 108,113,196 | 108,113,196 | 108,113,196 | ec,93,d3 | ba,8b,af | ba,8b,af |
| light cyan | 0,255,255 | 85,255,255 | 143,188,187 | 147,161,161 | 147,161,161 | 147,161,161 | 93,e0,e3 | 86,c1,b9 | 86,c1,b9 |
| white | 255,255,255 | 255,255,255 | 236,239,244 | 253,246,227 | 253,246,227 | 253,246,227 | dc,dc,cc | ff,ff,ff | ff,ff,ff |
| **foreground** | 229,229,229 | 170,170,170 | 216,222,233 | 238,232,213 | 238,232,213 | **7,54,66** | dc,dc,cc | d8,d8,d8 | 18,18,18 |
| **background** | 0,0,0 | 0,0,0 | 46,52,64 | 7,54,66 | 0,0,0 | **238,232,213** | 2c,2c,2c | 18,18,18 | d8,d8,d8 |

Source for each row: `color_palette_legacy` `tsm-vte.c:214-233`,
`color_palette_vga` `236-255`, `color_palette_nord` `254-274`,
`color_palette_solarized` `276-296`, `solarized_black` `298-318`,
`solarized_white` `320-340`, `soft_black` `342-362`, `base16_dark`
`364-384`, `base16_light` `386-406`. Note that `solarized-white` keeps the
same 16 ANSI slots as `solarized` and only swaps the default fg/bg pair:
fg = `7,54,66` (base02, #073642), bg = `238,232,213` (base2, #eee8d5) —
base03 (#002b36) and base3 (#fdf6e3) appear in the palette only as ANSI
"dark grey" (slot 8) and "white" (slot 15). Values written as bare two-digit
hex pairs without a `0x` prefix (the `soft-black` and `base16-*` rows; the
source literals are `0x70` etc., `tsm-vte.c:342-406`) are hexadecimal, not
decimal: `70,50,50` is 0x70,0x50,0x50 = 112,80,80. The `--palette-*` options
themselves parse with `strtoul(…, 0)` (`shl_strtou`, `shl/misc.h:64-83`), so
there `0x70` is hex, a bare `70` is decimal 70, and a leading `0` means octal.

kmscon wires the palette via `tsm_vte_set_palette` +
`tsm_vte_set_custom_palette(term->conf->custom_palette)` (`terminal.c:1471-1477`).

## 6. `--help` and `--version` output shape

### `--version` (`config.c:849-882`)

```
kmscon version %s              ← %s = shl_git_head
```

`shl_git_head` is generated by meson `vcs_tag`: `git describe --tags` when
building from a git checkout, else the fallback `'v' + meson.project_version()`
= **`v10.1.0`** for the release tarball (`src/meson.build:8-12`,
`src/shl/githead.c.in`).

With `--verbose` set (argv order irrelevant: `conf_ctx_parse_argv` finishes the
whole getopt loop before afterchecks run, `misc/conf.c:313-315`), extra lines
follow:

```
Compiled: <__DATE__> <__TIME__>
Build options:
  - DRM 2D support: enabled|disabled      ← BUILD_ENABLE_VIDEO_DRM2D
  - DRM 3D support: enabled|disabled      ← BUILD_ENABLE_VIDEO_DRM3D
  - FBDEV support: enabled|disabled       ← BUILD_ENABLE_VIDEO_FBDEV
  - Pango font support: enabled|disabled  ← BUILD_ENABLE_FONT_PANGO
```

### `--help` (`config.c:46-310`)

`-h`/`--help` triggers the help aftercheck, prints to **stdout**, and sets
`exit` so kmscon quits right after argument parsing. Exact structure of the
printed text (format strings copied from `print_help()`):

```
Usage:
	<argv0> [options]
	<argv0> -h [options]
	<argv0> -l [options] -- /bin/login [login-arguments]

You can prefix boolean options with "no-" to negate them. If an argument is
given multiple times, only the last argument matters if not otherwise stated.
```

Then, in order, the groups below (option, default in `[brackets]`):

- **General Options**: `-h, --help`; `-V, --version`; `-v, --verbose [off]`;
  `--debug [off]`; `--silent [off]`; `-c, --configdir </foo/bar> [<BUILD_CONFIG_DIR>]`.
- **Seat Options**: `--vt <vt> [auto]`; `--switchvt [on]`; `--libseat [on]`.
- **Session Options**: `--session-max <max> [50]`; `--session-control [off]`.
- **Terminal Options**: `-l, --login [/bin/login -p]`; `--oneshot [off]`;
  `-t, --term <TERM> [<BUILD_DEFAULT_TERM>]`; `--reset-env [on]`;
  `--issue [on]`; `--issue-path <path> [<ISSUE_DEFAULT_PATH>]`;
  `--asciicast <path>`; `--asciicast-loop [off]`;
  `--backspace-delete [on]`; `--sb-size <num> [1000]`; `--bell [off]`;
  `--blink [on]`.
- **Input Options**: `--xkb-model <model> [-]`; `--xkb-layout <layout> [-]`;
  `--xkb-variant <variant> [-]`; `--xkb-options <options> [-]`;
  `--xkb-keymap <FILE> [-]`; `--xkb-compose-file <FILE> [-]`;
  `--xkb-repeat-delay <msecs> [250]`; `--xkb-repeat-rate <msecs> [50]`;
  `--mouse [on]`; `--natural-scrolling [off]`; `--soft-cursor [off]`;
  `--dpms-timeout <secs> [600]`.
- **Grabs / Keyboard-Shortcuts**: each `--grab-* <grab>` with defaults as in
  §5.7 (`[<Shift>Up]`, `[<Shift>Down]`, `[<Shift>Prior]`, `[<Shift>Next]`,
  `[<Ctrl>plus]`, `[<Ctrl>minus]`, `[<Ctrl><Logo>Right]`,
  `[<Ctrl><Logo>Left]`, `[<Ctrl><Logo>BackSpace]`, `[<Ctrl><Logo>Return]`,
  `[<Logo>plus]`, `[<Logo>minus]`, `[]` for grab-reboot with "Reboot the
  system (disabled by default)").
- **Video Options**: `--drm [on]`; `--hwaccel [off]`;
  `--gpus={all,aux,primary} [all]`; `--use-original-mode [off]`;
  `--mode <gpu>[<connector>]<width>x<height>@<rate>`; `--screen
  <gpu>[<connector>]<orientation|disabled>`. ⚠ **`--multi-monitor` does not
  appear in `--help`** even though it is a real option.
- **Font Options**: `--font-engine <engine> [freetype]`; `--font-size
  <pixels> [0]`; `--font-name <name> [monospace]`.
- **Palette Options**: `--palette <name> [default]` ("specify `custom' to use
  the following color options") and the 18 `--palette-*` options with their
  default RGB tuples (see master table; `[229, 229, 229]` etc.).

(In real `--version`, the string literal is `"kmscon version %s\n"` — print
`kmshaunt version …` accordingly, but keep the shape and the `Compiled:` /
`Build options:` block layout for parity tests.)

## 7. FAQs / gotchas for parity

- Help says "If an argument is given multiple times, only the last argument
  matters if not otherwise stated" — exceptions: `mode`
  and `screen` accumulate; `login` is one-shot-consume-remaining-argv on CLI.
- Bool defaults are **on** for: `switchvt`, `issue`, `reset-env`,
  `backspace-delete`, `blink`, `mouse`, `drm` (all others off).
- `--drm` at runtime is forced off if neither drm2d nor drm3d was compiled in
  (`aftercheck_drm` `config.c:889-915`).
- Grabs match **exact** modifier sets — Ctrl+Logo+Right does not fire when
  Shift is also held.
- `--session-control` silently cancels itself on real VTs
  (`seat.c:780-784`), so session grabs (and grab-reboot, which is not gated)
  only make sense on fake-VT/libseat seats.
- `term` env default `kmscon` (meson option `term`); the nixpkgs kmscon build
  does not override it. kmshaunt's D6 (`xterm-ghostty`) is a deliberate
  deviation.
- The kmscon.conf.5 example file contains a stale `rotate=normal` line — no
  `rotate` option exists; rotation is `screen=…` orientations. The kmscon.1
  man page also references a non-existent `--seats` option in the `--vt`
  description. Source is authoritative.

## 8. Completeness cross-check vs ROADMAP appendix

Every option in the ROADMAP appendix parity matrix is present in this
document with its exact source default:

| Appendix group | Options | Doc § |
|---|---|---|
| Global | help, version, verbose, debug, silent, configdir | §1, §6 |
| Seat | vt, switchvt, libseat | §5.1 |
| Session | session-max, session-control | §5.1 |
| Terminal | issue, issue-path, asciicast, asciicast-loop, login, oneshot, term, reset-env, backspace-delete, sb-size, bell, blink | §5.2 |
| Input | xkb-model, xkb-layout, xkb-variant, xkb-options, xkb-keymap, xkb-compose-file, xkb-repeat-delay, xkb-repeat-rate, mouse, natural-scrolling, soft-cursor, dpms-timeout | §1, §5 |
| Grabs | grab-scroll-up, grab-scroll-down, grab-page-up, grab-page-down, grab-zoom-in, grab-zoom-out, grab-session-next, grab-session-prev, grab-session-close, grab-terminal-new, grab-rotate-cw, grab-rotate-ccw, grab-reboot | §5.7 |
| Video | drm, hwaccel, gpus, use-original-mode, mode, multi-monitor, screen | §5.3, §5.4, §5.8 |
| Font | font-engine (freetype, pango alias, psf, unifont, 8x16), font-size, font-name | §5.9 |
| Palette | palette (solarized, solarized-black, solarized-white, soft-black, base16-dark, base16-light, vga, legacy, custom), palette-* | §5.10 |

Options/modes in source but **not** in the appendix (flagged explicitly):

1. `--palette=nord` — valid preset in libtsm 4.8.0, absent from appendix list.
2. `--gpus=auxiliary` and `--gpus=single` — accepted aliases for `aux` and
   `primary` (`config.c:471-476`).
3. `--multi-monitor` — in the appendix, but missing from `--help`.
4. `--xkb-compose-file` details: empty `""` = use default compose file for the
   locale (man 1); unset = system default.

No option in `src/config.c` is absent from this document.