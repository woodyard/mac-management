# mac-management

macOS management scripts for fleet maintenance, Intune MDM, and system administration.

## Scripts

### maintenance/mac-maintenance.sh

System maintenance script that performs two main tasks:

**1. Clear caches, old logs, and temp files**
- System and per-user caches (`/Library/Caches`, `~/Library/Caches`)
- Old system logs in `/var/log` (> 7 days)
- Old diagnostic reports (> 7 days)
- Temp files not accessed in 3+ days
- Intune and Company Portal log files (> 7 days)
- Software Update download cache

**2. Restart hung agents and services**
- Company Portal
- Intune MDM daemon (`IntuneMdmDaemon`)
- Intune sidecar agent
- Microsoft Defender (only if real-time protection is unresponsive)
- Apple MDM client (`mdmclient`)

#### Usage

```bash
sudo bash maintenance/mac-maintenance.sh
```

Requires root. Designed for deployment via Intune shell script policies.

#### Logging

All actions are logged to stdout and `syslog` with the tag `mac-maintenance`.
