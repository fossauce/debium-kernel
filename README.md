# debium-kernel

Debian's backports kernel for Debian stable, rebuilt with a few changes.
Not part of Debian.

## Changes

Debian's source, patches and amd64 config, except:

| | Debian | debium-kernel |
|---|---|---|
| Timer | 250 Hz | 1000 Hz |
| Preemption | lazy | full |
| Module compression | xz | zstd |
| `teo` idle governor | not built | built, not default |
| Console takeover | immediate | deferred |
| IRQ time accounting | off | on |
| In-tree modules | signed by Debian | signed with a per-build key |

Options: [options.config](options.config).

Patches in `patches/<series>/`, upstream and unchanged:

| Series | Patches | For |
|---|---|---|
| 7.2 | resolve_btfids kfunc tagging, from 7.3 | sched_ext schedulers |

## Install

```sh
sudo apt install ./linux-image-*_amd64.deb ./linux-headers-*_amd64.deb
```

Debian's kernel stays installed. New releases are not installed automatically.

Remove:

```sh
sudo apt purge '~n^linux-.*debium$'
```

## Limitations

- No Secure Boot.
- amd64 only.

## Build

Needs Debian stable with backports.

```sh
./build.sh                # newest series in backports
./build.sh -s 7.2 -r 2    # series 7.2, revision 2
./build.sh --configure    # stop after .config
```

Only apt runs as root, for missing build packages.

| Path | Contents |
|---|---|
| `cache/` | Debian source and config packages |
| `build/` | source tree, `build.log`, `config.diff` |
| `output/<tag>/` | packages, `SHA256SUMS`, `build-info.txt` |

Version: Debian's plus `+debium<revision>`, e.g. `7.2.11-1~bpo13+1+debium1`.
Kernel release: `7.2.11-debium`.
