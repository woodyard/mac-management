#!/bin/bash
#
# mac-maintenance.sh
# Clears caches, old logs, and temp files. Restarts known-hung agents/services.
# Intended to run as root (e.g., via Intune shell script deployment).
#

set -euo pipefail

LOG_TAG="mac-maintenance"

log() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $1"
    logger -t "$LOG_TAG" "$1"
}

# Require root
if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root." >&2
    exit 1
fi

log "=== Starting macOS maintenance ==="

# -------------------------------------------------------------------
# 1. Clear system caches, old logs, and temp files
# -------------------------------------------------------------------
log "--- Clearing caches and temp files ---"

# System caches
if [[ -d /Library/Caches ]]; then
    du_before=$(du -sm /Library/Caches 2>/dev/null | awk '{print $1}')
    find /Library/Caches -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} + 2>/dev/null || true
    du_after=$(du -sm /Library/Caches 2>/dev/null | awk '{print $1}')
    log "Cleared /Library/Caches (${du_before:-0}MB -> ${du_after:-0}MB)"
fi

# Per-user caches
for user_home in /Users/*/; do
    username=$(basename "$user_home")
    [[ "$username" == "Shared" || "$username" == "Guest" ]] && continue

    cache_dir="${user_home}Library/Caches"
    if [[ -d "$cache_dir" ]]; then
        du_before=$(du -sm "$cache_dir" 2>/dev/null | awk '{print $1}')
        find "$cache_dir" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} + 2>/dev/null || true
        du_after=$(du -sm "$cache_dir" 2>/dev/null | awk '{print $1}')
        log "Cleared $cache_dir for $username (${du_before:-0}MB -> ${du_after:-0}MB)"
    fi
done

# Old system logs (> 7 days)
if [[ -d /var/log ]]; then
    count=$(find /var/log -name "*.log" -mtime +7 -type f 2>/dev/null | wc -l | tr -d ' ')
    find /var/log -name "*.log" -mtime +7 -type f -delete 2>/dev/null || true
    find /var/log -name "*.log.gz" -mtime +7 -type f -delete 2>/dev/null || true
    log "Removed $count old log files from /var/log (older than 7 days)"
fi

# Old Apple diagnostic reports (> 7 days)
for diag_dir in /Library/Logs/DiagnosticReports /Users/*/Library/Logs/DiagnosticReports; do
    if [[ -d "$diag_dir" ]]; then
        find "$diag_dir" -type f -mtime +7 -delete 2>/dev/null || true
        log "Cleaned old diagnostic reports in $diag_dir"
    fi
done

# Temp files
for tmp_dir in /tmp /private/var/folders; do
    if [[ -d "$tmp_dir" ]]; then
        find "$tmp_dir" -type f -atime +3 -delete 2>/dev/null || true
        log "Cleaned temp files in $tmp_dir (not accessed in 3+ days)"
    fi
done

# Old Intune MDM agent logs (> 7 days)
intune_log_dir="/Library/Logs/Microsoft/Intune"
if [[ -d "$intune_log_dir" ]]; then
    find "$intune_log_dir" -type f -mtime +7 -delete 2>/dev/null || true
    log "Cleaned old Intune agent logs"
fi

# Old Company Portal logs
cp_log_dir="/Library/Logs/Microsoft/CompanyPortal"
if [[ -d "$cp_log_dir" ]]; then
    find "$cp_log_dir" -type f -mtime +7 -delete 2>/dev/null || true
    log "Cleaned old Company Portal logs"
fi

# Softwareupdate downloads cache
su_cache="/Library/Updates"
if [[ -d "$su_cache" ]]; then
    rm -rf "${su_cache:?}"/* 2>/dev/null || true
    log "Cleared Software Update download cache"
fi

log "--- Cache and log cleanup complete ---"

# -------------------------------------------------------------------
# 2. Restart agents/services known to hang
# -------------------------------------------------------------------
log "--- Restarting known-hung agents and services ---"

# Company Portal
cp_process="Company Portal"
if pgrep -x "$cp_process" > /dev/null 2>&1; then
    pkill -x "$cp_process" 2>/dev/null || true
    sleep 2
    log "Killed Company Portal process (it will relaunch on next user interaction)"
else
    log "Company Portal not running, skipping"
fi

# Intune MDM agent (IntuneMdmDaemon)
intune_daemon="IntuneMdmDaemon"
intune_plist="com.microsoft.intune.agent"
if pgrep -x "$intune_daemon" > /dev/null 2>&1; then
    launchctl unload "/Library/LaunchDaemons/${intune_plist}.plist" 2>/dev/null || true
    sleep 2
    launchctl load "/Library/LaunchDaemons/${intune_plist}.plist" 2>/dev/null || true
    log "Restarted Intune MDM daemon ($intune_daemon)"
else
    # Try to start it if not running at all
    if [[ -f "/Library/LaunchDaemons/${intune_plist}.plist" ]]; then
        launchctl load "/Library/LaunchDaemons/${intune_plist}.plist" 2>/dev/null || true
        log "Intune MDM daemon was not running, started it"
    else
        log "Intune MDM daemon plist not found, skipping"
    fi
fi

# Intune sidecar agent (used for script/policy execution)
sidecar_plist="com.microsoft.intune.agent.sidecar"
if [[ -f "/Library/LaunchDaemons/${sidecar_plist}.plist" ]]; then
    launchctl unload "/Library/LaunchDaemons/${sidecar_plist}.plist" 2>/dev/null || true
    sleep 2
    launchctl load "/Library/LaunchDaemons/${sidecar_plist}.plist" 2>/dev/null || true
    log "Restarted Intune sidecar agent"
fi

# Microsoft Defender (if installed and hung)
defender_daemon="wdavdaemon"
defender_plist="com.microsoft.wdav"
if pgrep -x "$defender_daemon" > /dev/null 2>&1; then
    # Check if Defender real-time protection is responsive
    if ! /usr/local/bin/mdatp health --field real_time_protection_enabled 2>/dev/null | grep -q "true"; then
        launchctl unload "/Library/LaunchDaemons/${defender_plist}.plist" 2>/dev/null || true
        sleep 3
        launchctl load "/Library/LaunchDaemons/${defender_plist}.plist" 2>/dev/null || true
        log "Restarted Microsoft Defender (real-time protection was unresponsive)"
    else
        log "Microsoft Defender is running and responsive, skipping"
    fi
else
    log "Microsoft Defender not running, skipping"
fi

# mdmclient (Apple's built-in MDM)
if ! profiles status -type enrollment 2>/dev/null | grep -q "Yes"; then
    log "Device not MDM enrolled via profiles, skipping mdmclient restart"
else
    killall mdmclient 2>/dev/null || true
    sleep 2
    log "Restarted mdmclient (Apple MDM client)"
fi

log "--- Agent/service restarts complete ---"
log "=== macOS maintenance finished ==="

exit 0
