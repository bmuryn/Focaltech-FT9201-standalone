Markdown
# FocalTech FT9201 (2808:93a9) Standalone Driver for Debian/Ubuntu

Standalone installation stack for the FocalTech FT9201 fingerprint reader (`2808:93a9`).
Bundles the patched proprietary FocalTech driver, `libgusb` shim, and an isolated `fprintd` runtime in `/opt/focaltech` to prevent conflicts with distribution package updates.

## Quick Install (Pre-built package)

Download the `.deb` package from the [Releases](https://github.com/TWOJA_NAZWA/focaltech-ft9201/releases) tab:

```bash
sudo apt install ./focaltech-ft9201-standalone_2.0.0_amd64.deb
fprintd-enroll $USER
