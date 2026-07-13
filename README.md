<div align="center">

```
      _       _____
     (/      |  __ \
    (  )     | |__) |__  __ _ _ __
   /    \    |  ___/ _ \/ _` | '__|
  ( ^ u ^ )  | |  |  __/ (_| | |
   \.___./   |_|   \___|\__,_|_|
```

```
     /\_/\
 ___/ o o \
/___   =-= /
\____)-m-m)
```

<em>A fast, friendly macOS cleanup CLI. Clean, uninstall, analyze, optimize, and monitor your Mac from the terminal.</em>

<sub>Named after Pear 🍐</sub>

</div>

## Features

- **All-in-one toolkit**: cleanup, uninstall, disk analysis, and live monitoring in a **single binary**
- **Deep cleaning**: removes caches, logs, leftovers, and orphaned app data to **reclaim gigabytes of space**
- **Smart uninstaller**: removes apps plus launch agents, preferences, and **hidden remnants**
- **Disk insights**: visualizes usage, finds large files, **rebuilds caches**, and refreshes system services
- **Live monitoring**: shows real-time CPU, GPU, memory, disk, and network stats

## Install

Pear is built for macOS. There is no Homebrew tap yet, so install from source.

**Via script**

```bash
# Optional args: -s latest for main branch code, -s 1.45.0 for a specific version
curl -fsSL https://raw.githubusercontent.com/RawSalmon69/pear-cli/main/install.sh | bash
```

**Or clone and run the installer**

```bash
git clone https://github.com/RawSalmon69/pear-cli.git
cd pear-cli
./install.sh
```

## Usage

`pe` also works as a shorthand alias for every command below.

```bash
pear                           # Interactive menu
pear clean                     # Deep cleanup + already-uninstalled app leftovers
pear uninstall                 # Remove installed apps + their leftovers
pear optimize                  # Refresh caches & services
pear analyze                   # Visual disk explorer (or 'pear analyse')
pear status                    # Live system health dashboard
pear purge                     # Clean project build artifacts
pear installer                 # Find and remove installer files

pear touchid                   # Configure Touch ID for sudo
pear completion                # Set up shell tab completion
pear update                    # Update Pear
pear update --nightly          # Update to latest unreleased main build, script install only
pear remove                    # Remove Pear from system
pear --help                    # Show help
pear --version                 # Show installed version
```

**Preview safely**

```bash
pear clean --dry-run
pear uninstall --dry-run
pear history
pear history --json
pear purge --dry-run

# Also works with: optimize, installer, remove, completion, touchid enable
pear clean --dry-run --debug   # Preview + detailed logs
pear optimize --whitelist      # Manage protected optimization rules
pear clean --whitelist         # Manage protected caches
pear purge --paths             # Configure project scan directories
pear analyze /Volumes          # Analyze external drives only
```

## Security & Safety Design

Pear is a local system maintenance tool, and some commands can perform destructive local operations.

Pear uses safety-first defaults: path validation, protected-directory rules, conservative cleanup boundaries, and explicit confirmation for higher-risk actions. When risk or uncertainty is high, Pear skips, refuses, or requires stronger confirmation rather than broadening deletion scope.

`pear analyze` is safer for ad hoc cleanup because it moves files to Trash through Finder instead of deleting them directly.

Review [SECURITY.md](SECURITY.md) and [SECURITY_AUDIT.md](SECURITY_AUDIT.md) for reporting guidance, safety boundaries, and current limitations.

## Tips

- Safety and logs: `clean`, `uninstall`, `purge`, `installer`, and `remove` are destructive. Review with `--dry-run` first, and add `--debug` when needed. File operations are logged to `~/Library/Logs/pear/operations.log` and can be reviewed with `pear history`. Disable with `PE_NO_OPLOG=1`.
- App leftovers: use `pear clean` when the app is already uninstalled, and `pear uninstall` when the app is still installed.
- Navigation: Pear supports arrow keys and Vim bindings `h/j/k/l`.

## Features in Detail

### Deep System Cleanup

```bash
$ pear clean

Scanning cache directories...

  ✓ User app cache                                           45.2GB
  ✓ Browser cache (Chrome, Safari, Firefox)                  10.5GB
  ✓ Developer tools (Xcode, Node.js, npm)                    23.3GB
  ✓ System logs and temp files                                3.8GB
  ✓ App-specific cache (Spotify, Dropbox, Slack)              8.4GB
  ✓ Trash                                                    12.3GB

====================================================================
Space freed: 95.5GB | Free space now: 223.5GB
====================================================================
```

### Smart App Uninstaller

```bash
$ pear uninstall

Select Apps to Remove
═══════════════════════════
▶ ☑ Photoshop 2024            (4.2G) | Old
  ☐ IntelliJ IDEA             (2.8G) | Recent
  ☐ Premiere Pro              (3.4G) | Recent

Uninstalling: Photoshop 2024

  ✓ Removed application
  ✓ Cleaned 52 related files across 12 locations
    - Application Support, Caches, Preferences
    - Logs, WebKit storage, Cookies
    - Extensions, Plugins, Launch daemons

====================================================================
Space freed: 12.8GB
====================================================================
```

### System Optimization

```bash
$ pear optimize

System: 5/32 GB RAM | 333/460 GB Disk (72%) | Uptime 6d

  ✓ Rebuild system databases and clear caches
  ✓ Reset network services
  ✓ Refresh Finder and Dock
  ✓ Clean diagnostic and crash logs
  ✓ Remove swap files and restart dynamic pager
  ✓ Rebuild launch services and spotlight index

====================================================================
System optimization completed
====================================================================
```

Use `pear optimize --whitelist` to exclude specific optimizations. Path patterns work too, so you can keep a long-lived mounted disk image around (for example `/Volumes/mail`) without it showing up as a detach candidate.

### Disk Space Analyzer

> Note: By default, Pear skips external drives under `/Volumes` for faster startup. To inspect them, run `pear analyze /Volumes` or a specific mount path.

```bash
$ pear analyze

Analyze Disk  ~/Documents  |  Total: 156.8GB

 ▶  1. ███████████████████  48.2%  |  📁 Library                     75.4GB  >6mo
    2. ██████████░░░░░░░░░  22.1%  |  📁 Downloads                   34.6GB
    3. ████░░░░░░░░░░░░░░░  14.3%  |  📁 Movies                      22.4GB
    4. ███░░░░░░░░░░░░░░░░  10.8%  |  📁 Documents                   16.9GB
    5. ██░░░░░░░░░░░░░░░░░   5.2%  |  📄 backup_2023.zip              8.2GB

  ↑↓←→ Navigate  |  O Open  |  F Show  |  ⌫ Delete  |  L Large files  |  Q Quit
```

### Live System Status

Real-time dashboard with health score, hardware info, and performance metrics.

```bash
$ pear status

Pear Status  Health ● 92  MacBook Pro · M4 Pro · 32GB · macOS 14.5

⚙ CPU                                    ▦ Memory
Total   ████████████░░░░░░░  45.2%       Used    ███████████░░░░░░░  58.4%
Load    0.82 / 1.05 / 1.23 (8 cores)     Total   14.2 / 24.0 GB
Core 1  ███████████████░░░░  78.3%       Free    ████████░░░░░░░░░░  41.6%
Core 2  ████████████░░░░░░░  62.1%       Avail   9.8 GB

▤ Disk                                   ⚡ Power
Used    █████████████░░░░░░  67.2%       Level   ██████████████████  100%
Free    156.3 GB                         Status  Charged
Read    ▮▯▯▯▯  2.1 MB/s                  Health  Normal · 423 cycles
Write   ▮▮▮▯▯  18.3 MB/s                 Temp    58°C · 1200 RPM

⇅ Network                                ▶ Processes
Down    ▁▁█▂▁▁▁▁▁▁▁▁▇▆▅▂  0.54 MB/s      Code       ▮▮▮▮▯  42.1%
Up      ▄▄▄▃▃▃▄▆▆▇█▁▁▁▁▁  0.02 MB/s      Chrome     ▮▮▮▯▯  28.3%
Proxy   HTTP · 192.168.1.100             Terminal   ▮▯▯▯▯  12.5%
```

Health score is based on CPU, memory, disk, temperature, and I/O load, with color-coded ranges. In `pear status`, press `k` to toggle the cat mascot and save the preference, and `q` to quit.

#### Machine-Readable Output

Both `pear analyze` and `pear status` support a `--json` flag for scripting and automation. `pear status` also auto-detects when its output is piped (not a terminal) and switches to JSON automatically.

```bash
# Disk analysis as JSON
$ pear analyze --json ~/Documents

# System status as JSON
$ pear status --json

# Auto-detected JSON when piped
$ pear status | jq '.health_score'
92
```

### Project Artifact Purge

Clean old build artifacts such as `node_modules`, `target`, `.build`, `build`, and `dist` to free up disk space.

```bash
pear purge

Select Categories to Clean - 18.5GB (8 selected)

➤ ● my-react-app       3.2GB | node_modules
  ● old-project        2.8GB | node_modules
  ● rust-app           4.1GB | target
  ● next-blog          1.9GB | node_modules
  ○ current-work       856MB | node_modules  | Recent
  ● django-api         2.3GB | venv
  ● vue-dashboard      1.7GB | node_modules
  ● backend-service    2.5GB | node_modules
```

> Note: We recommend installing `fd` on macOS (`brew install fd`).
>
> Safety: This permanently deletes selected artifacts. Review carefully before confirming. Projects newer than 7 days are marked and unselected by default.

Run `pear purge --paths` to configure scan directories, or edit `~/.config/pear/purge_paths` directly. When custom paths are configured, Pear scans only those directories. Otherwise, it uses defaults like `~/Projects`, `~/GitHub`, and `~/dev`.

### Installer Cleanup

Find and remove large installer files across Downloads, Desktop, Homebrew caches, iCloud, and Mail. Each file is labeled by source.

```bash
pear installer

Select Installers to Remove - 3.8GB (5 selected)

➤ ● Photoshop_2024.dmg     1.2GB | Downloads
  ● IntelliJ_IDEA.dmg       850.6MB | Downloads
  ● Illustrator_Setup.pkg   920.4MB | Downloads
  ● PyCharm_Pro.dmg         640.5MB | Homebrew
  ● Acrobat_Reader.dmg      220.4MB | Downloads
  ○ AppCode_Legacy.zip      410.6MB | Downloads
```

## Acknowledgements & License

Pear is a fork of [Mole](https://github.com/tw93/Mole) by tw93, licensed GPL-3.0. Renamed in accordance with Mole's trademark policy. All credit for the original engineering goes to the Mole project.

Pear is open source under GPL-3.0, see [LICENSE](LICENSE). A version you modify and share stays open under the same license.
