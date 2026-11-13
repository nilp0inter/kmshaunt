# kmshaunt ↔ kmscon parity matrix

Status of kmscon 10.x feature parity. Legend: ✅ done (verified) · 🟡 partial/in flight · ⬜ not started · ❌ blocked.
Test tiers: T1 unit · T2 render golden · T3 VM integration · T4 parity (same scenario on kmscon + kmshaunt).

Last updated: 2026-11-13. This file is ticked as features land; `nix flake check` runs T1 + the wired T3/T4 checks.

## Session / system
| Feature | Status | Evidence / gap |
|---|---|---|
| `kmshaunt-vt@.service` as autovt@, getty fallback | ✅ | M1.7/M1.8; T4 m1-login green |
| Multi-seat `kmshaunt.service` (sd-login) | 🟡 | M6.2 daemon; skips seats without a fake VT worker |
| PAM service, locale1 xkb | ✅ | M1.7, M6.5 |
| `session-max`, `session-control` | 🟡 | M6.3 manager; real-VT gate being added |
| `libseat` backend | ✅ | Startup segfault fixed: `setCallbacks` no longer fires queued enable, `activate()` delivers it; T1 real-ops regression + T3 m6-libseat-startup green on tensor (unit active, no segfault, logind greeter seat, autologin shell) |

## Terminal
| Feature | Status | Evidence / gap |
|---|---|---|
| pty replies DA/DSR/size, bell, OSC52, private OSC setBackground/setForeground | ✅ | M2.1 |
| `sb-size`, grab-scroll-*/page-* | ✅ | M2.2 |
| `term`, `reset-env`, `login`, `oneshot` | ✅ | M1.4, M2.4 |
| `issue`/`issue-path` agetty escapes | ✅ | M2.4 |
| `backspace-delete` | ✅ | M2.4 |
| `blink` (cursor) | ✅ | timer wired, repaint verified |
| SGR text blink (attr 5) | ✅ | attr-5 blink wired; repaint verified |
| palettes (presets + custom + palette-*) | ✅ | applied to terminal via `applyPalette`; presets, custom, xterm256 |
| `asciicast`/`asciicast-loop` | 🟡 | semantics = playback (kmscon §5.2); recording→playback cutover in flight |
| resize on mode change + reflow | 🟡 | zoom/rotate wired; mode-change resize wiring in flight |

## Input
| Feature | Status | Evidence / gap |
|---|---|---|
| libinput keyboard, xkbcommon, key encoder | ✅ | M1.6 |
| mouse selection/copy/paste/reporting, natural-scrolling, soft cursor | ✅ | M2.3 (545 tests) |
| xkb-model/layout/variant/options/keymap/compose-file/repeat-* | ✅ | M6.5 |
| locale1 live keymap follow | ✅ | M6.5; T4 m6-seats S1 |
| compose | ✅ | T4 m6-seats S2 |
| absolute-pointer transform (tablets) | ⬜ | libinput _transformed getters (M5.7 note) |

## Grabs
| Feature | Status | Evidence / gap |
|---|---|---|
| scroll/page/zoom/session/terminal-new | ✅ | M2.2, M3.8, M6.3 |
| grab-rotate-cw/ccw | 🟡 | rotation helper ready; VideoWiring wiring in flight |
| grab-reboot | 🟡 | ctrl-alt-del semantics in flight (writes kernel ctrl-alt-del flag + sync) |

## Video
| Feature | Status | Evidence / gap |
|---|---|---|
| drm2d modeset + dumb buffers + flip | ✅ | M1.3 |
| drm3d GBM+EGL+GLES2, hwaccel | ✅ | M5.1 |
| fbdev (no-drm) | ✅ | M5.2 |
| gpus/use-original-mode/mode= | ✅ | backend + VideoWiring main.zig |
| multi-monitor clone/largest/scaled, screen= | 🟡 | multi-card done; same-card multi-connector scanout in flight |
| udev hotplug | ✅ | event source + VideoWiring wired |
| dpms-timeout | 🟡 | primary connector done; all-connector idle/wake in flight |
| hardware cursor plane + soft-cursor force | ✅ | backend + gate wiring |

## Font / text (R1)
| Feature | Status | Evidence / gap |
|---|---|---|
| fontconfig discovery + synthetic styles | ✅ | M3.1 |
| per-codepoint fallback | ✅ | M3.2 |
| HarfBuzz shaping + font-features | ✅ | M3.3 |
| grapheme clusters | ✅ | M3.4 |
| color glyphs CBDT/sbix/COLRv0/v1 | ✅ | M3.5 |
| sprites box/blocks/braille/powerline/legacy | ✅ | M3.6 |
| decorations + cursor styles | ✅ | M3.7 |
| atlas LRU, font-size auto, grab-zoom | ✅ | M3.8 |
| psf/unifont/8x16 engines | ✅ | M3.9 |
| T2 goldens + T3 VM golden | 🟡 | 19 goldens byte-exact, nix check in flight; T3 VM golden pending |

## Kitty graphics (R2)
| Feature | Status | Evidence / gap |
|---|---|---|
| libspng decoder, image cache, CPU compositor | ✅ | M4.1-M4.3 |
| animation, storage-limit, R3 root media off | ✅ | M4.4/M4.5 (551+16 tests) |
| T2 kitty goldens + T3 kitten icat | 🟡 | fixtures generated; nix check in flight; T3 kitten icat pending |

## Performance (M8)
| Feature | Status | Evidence / gap |
|---|---|---|
| vtebench throughput vs kmscon | 🟡 | M8.1; benchmark running on tensor |
| damage-only presentation | 🟡 | M8.2; analysis done, implementation in flight |
| memory @10k scrollback | 🟡 | M8.3; measurement in flight |
| T5 real-hardware checklist | ⬜ | M8.4 (needs ≥2 GPU vendors; assess) |
| docs/perf.md | 🟡 | M8.5; being written |