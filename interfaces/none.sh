#!/bin/bash
#
# Bashobot Interface: Dummy/None
#
# Used when running in pure CLI mode without external interfaces
#

# Start interface - does nothing for dummy
interface_receive() {
    log_info "Dummy interface started (no external connections)"
    
    # Just keep alive, the pipe handling is in main loop
    while true; do
        sleep 3600
    done
}

# Send message via interface - no-op for dummy
interface_reply() {
    local session_id="$1"
    local message="$2"
    # No external interface to send to
    :
}


# Interface info
interface_info() {
    echo "Interface: None (CLI only)"
}
