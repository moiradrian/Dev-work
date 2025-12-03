# Move_RefCounts_3.3.5 — Quick User Guide

A short, non-technical guide to install and run the refcount migration script with its standard options.

## What the script does
- Moves refcount data from the main repository drive to an SSD for better performance.
- Updates the QoreStor config so refcounts use the SSD.
- Creates a dated backup of the config and a run log.

## Install (one time)
1. Copy `Move_RefCounts_3.3.5.sh` to the target server.
2. Make it executable: `chmod +x Move_RefCounts_3.3.5.sh`.
3. Ensure you can run it with permissions to:
   - Stop/start the `ocards` service.
   - Edit `/etc/oca/oca.cfg`.
   - Write logs to `/var/log/oca_edit/`.

## How to run (common options)
All commands run from the script directory. Replace `/mnt/ssdvol` with your SSD mount path (must be a mounted filesystem for a live run).

- Dry run (full rehearsal, no changes):  
  `bash Move_RefCounts_3.3.5.sh --dry-run /mnt/ssdvol`

- Plan-only dry run (if SSD not mounted yet):  
  `bash Move_RefCounts_3.3.5.sh --dry-run`

- Scan refcount sizes only (no copy or config):  
  `bash Move_RefCounts_3.3.5.sh --scan-only`

- Copy only (no service stop/restart, no config edits):  
  `bash Move_RefCounts_3.3.5.sh --copy-only /mnt/ssdvol`

- Full live run (stop service, copy, verify optional, update config, restart):  
  `bash Move_RefCounts_3.3.5.sh /mnt/ssdvol`

- Stronger verification (slower; adds checksums during verify):  
  add `--checksum-verify` to any mode, e.g.  
  `bash Move_RefCounts_3.3.5.sh --copy-only --checksum-verify /mnt/ssdvol`

## What you’ll see
- Progress bars while copying.
- A summary at the end (mode, actions taken, any warnings).
- Log file: `/var/log/oca_edit/oca_edit_<timestamp>.log`.
- Config backup: `/etc/oca/oca.cfg.refcount_script.bak_<timestamp>`.

## Tips
- Use `--dry-run` first to confirm sizes, planned changes, and the mount path.
- For the live run, make sure the SSD path is mounted and has enough space.
- If you cancel, rerun with the same command when ready.
