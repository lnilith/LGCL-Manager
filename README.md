# LGCL — Linux Gaming Compatibility Layer Manager

LGCL is a production-grade system optimizer designed to bridge the gap between Linux systems and modern PC gaming. It intelligently tunes your Linux kernel and environment to behave robustly, ensuring maximum compatibility and performance for Windows-based games.

## Features

* **Hardware-Adaptive Tuning:** Automatically calculates memory limits (`vm.max_map_count`) and file descriptors based on your specific RAM and CPU threads. Perfect for hardware setups like an **RTX 3050 combined with an i3 processor**.

* **Stealth-First Architecture:** Designed to minimize kernel footprint, preventing triggers in games with strict anti-cheat software.

* **Snapshot & Rollback Engine:** Automatically backs up your system configurations before making any changes. If anything feels unstable, you can revert instantly.

* **Anti-Cheat Awareness:** Integrates harmoniously with Easy Anti-Cheat (EAC) and BattlEye environments on Linux.

## Supported Titles

LGCL prepares your Linux machine to run games as smoothly as they would on a Steam Deck.

### Steam Games
Prevents memory crashes and stuttering in resource-heavy titles:
* **Elden Ring**
* **Cyberpunk 2077**
* **Apex Legends**
* **Red Dead Redemption 2**

### Non-Steam Games & External Launchers
Creates the perfect environment for games running through Heroic Games Launcher, Bottles, or Anime Game Launcher:
* **Genshin Impact** (Eliminates the startup crash by fixing memory mapping limits).
* **Wuthering Waves** (Optimizes shader caching overhead).
* **Honkai: Star Rail**.
* **League of Legends**.

## Installation

1. **Clone the repository:**
```bash
git clone [https://github.com/lnilith/LGCL-Manager.git](https://github.com/lnilith/LGCL-Manager.git)
cd LGCL-Manager
```

2. **Make the script executable:**
```bash
chmod +x lgcl-manager.sh
```

## Usage

Run the script with `sudo` to allow kernel-level optimizations.

**Apply the Recommended Profile (Balanced):**
```bash
sudo ./lgcl-manager.sh --apply balanced
```

**Available Profiles:**
* `stealth`: Maximum safety for anti-cheat games. Minimal system changes.
* `balanced`: Best overall choice. Great performance while maintaining system stability.
* `performance`: Disables safety limits for maximum hardware utilization.

**Rollback Changes:**
```bash
sudo ./lgcl-manager.sh --rollback
```

**Dry Run (Test without making changes):**
```bash
./lgcl-manager.sh --apply balanced --dry-run
```

## Requirements
* **Linux Distribution:** Arch, Debian/Ubuntu, or Fedora/RHEL families.
* **Standard utilities:** `curl`, `lspci`, `sha512sum`, `sysctl`.

## License
This project is licensed under the MIT License - see the LICENSE file for details.
