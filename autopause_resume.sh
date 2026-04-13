#!/bin/sh

# ==========================================
# Flarewifi Auto-Pause/Resume Prototype
# ==========================================

# Configuration
POLL_INTERVAL=10          # Seconds between checks (keep low for fast auto-resume)
INACTIVE_TIME=300         # 5 minutes (300 seconds) of inactivity required to pause
PAUSE_THRESHOLD=100       # Bytes allowed over 5 mins before pausing
RESUME_THRESHOLD=500      # Bytes spike required to trigger resume
API_URL="https://api.yourserver.com/endpoint" # Replace with your actual central server API

# Ensure custom nftables table/chains exist
nft list table inet flare_autopause >/dev/null 2>&1 || {
    echo "Initializing nftables custom chains..."
    nft add table inet flare_autopause
    nft add chain inet flare_autopause forward_drop '{ type filter hook forward priority -1; policy accept; }'
    nft add set inet flare_autopause paused_macs '{ type ether_addr; }'
    nft add set inet flare_autopause byte_track '{ type ether_addr; flags dynamic; size 65535; timeout 10m; }'
    nft add rule inet flare_autopause forward_drop update @byte_track '{ ether saddr counter }'
    nft add rule inet flare_autopause forward_drop ether saddr @paused_macs drop
}

# State directory in RAM
STATE_DIR="/tmp/flare_state"
mkdir -p "$STATE_DIR"

echo "Starting Flarewifi Auto-Pause Manager..."

while true; do
    CURRENT_TIME=$(date +%s)

    # Dump the current byte counters from nftables and parse MACs and Bytes
    # Expected nft output format:  elements = { 00:11... counter packets 5 bytes 1234 }
    nft -n list set inet flare_autopause byte_track | grep "counter" | while read -r line; do
        
        # Extract MAC address and Byte count using awk
        MAC=$(echo "$line" | awk '{print $1}')
        CURRENT_BYTES=$(echo "$line" | awk '{print $7}')
        
        # Normalize MAC for filename usage (replace colons with underscores)
        MAC_FILE=$(echo "$MAC" | sed 's/:/_/g')
        STATE_FILE="$STATE_DIR/$MAC_FILE"
        
        # Initialize state file if new device
        if [ ! -f "$STATE_FILE" ]; then
            # Format: LastActiveTimestamp PreviousBytes IsPaused(0=No, 1=Yes)
            echo "$CURRENT_TIME $CURRENT_BYTES 0" > "$STATE_FILE"
            continue
        fi

        # Read previous state
        read -r LAST_ACTIVE PREV_BYTES IS_PAUSED < "$STATE_FILE"
        
        # Calculate bytes used since last poll
        BYTE_DELTA=$((CURRENT_BYTES - PREV_BYTES))
        
        # ---------------------------------------------------------
        # LOGIC 1: AUTO-RESUME TRIGGER
        # ---------------------------------------------------------
        if [ "$IS_PAUSED" -eq 1 ]; then
            if [ "$BYTE_DELTA" -ge "$RESUME_THRESHOLD" ]; then
                echo "[RESUME] Spike of $BYTE_DELTA bytes detected for $MAC."
                
                # ---> API CALL GOES HERE <---
                # Example: TIME_LEFT=$(uclient-fetch -O - -q "http://api.flarewifi.com/check?mac=$MAC")
                TIME_LEFT=10 # Mocking response for testing: assuming user has time
                
                if [ "$TIME_LEFT" -gt 0 ]; then
                    echo "Restoring internet for $MAC..."
                    nft delete element inet flare_autopause paused_macs "{ $MAC }"
                    # Reset state to active
                    echo "$CURRENT_TIME $CURRENT_BYTES 0" > "$STATE_FILE"
                else
                    echo "Time is 0 or less. Keeping internet blocked."
                    # Keep paused state, just update bytes to prevent constant API spam
                    echo "$LAST_ACTIVE $CURRENT_BYTES 1" > "$STATE_FILE"
                fi
                continue
            else
                # Still paused, just update bytes
                echo "$LAST_ACTIVE $CURRENT_BYTES 1" > "$STATE_FILE"
                continue
            fi
        fi

        # ---------------------------------------------------------
        # LOGIC 2: AUTO-PAUSE TRIGGER
        # ---------------------------------------------------------
        if [ "$IS_PAUSED" -eq 0 ]; then
            # If they used more than the tiny background threshold, update their last active time
            if [ "$BYTE_DELTA" -gt "$PAUSE_THRESHOLD" ]; then
                echo "$CURRENT_TIME $CURRENT_BYTES 0" > "$STATE_FILE"
            else
                # They didn't move enough data. Check if it's been 5 minutes since LAST_ACTIVE
                IDLE_TIME=$((CURRENT_TIME - LAST_ACTIVE))
                
                if [ "$IDLE_TIME" -ge "$INACTIVE_TIME" ]; then
                    echo "[PAUSE] $MAC inactive for $IDLE_TIME seconds. Blocking internet."
                    
                    # ---> API CALL GOES HERE <---
                    # Example: uclient-fetch -q -X POST -d "mac=$MAC&status=auto_paused" http://api.flarewifi.com/sync
                    
                    # Add to firewall drop list
                    nft add element inet flare_autopause paused_macs "{ $MAC }"
                    
                    # Update state to Paused (1)
                    echo "$CURRENT_TIME $CURRENT_BYTES 1" > "$STATE_FILE"
                else
                    # Still active but currently idling, just update the byte counter
                    echo "$LAST_ACTIVE $CURRENT_BYTES 0" > "$STATE_FILE"
                fi
            fi
        fi
    done
    
    sleep "$POLL_INTERVAL"
done