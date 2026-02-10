#!/bin/bash

# --- Color Definitions (256-color mode) ---
# We use a gradient to simulate the rounded/shell 3D effect
# Top: Salmon/Pinkish Highlight
C_TOP='\033[38;5;210m'
# Upper Mid: Vibrant Orange-Red
C_MID1='\033[38;5;202m'
# Lower Mid: Pure Red
C_MID2='\033[38;5;196m'
# Bottom: Dark Red/Maroon
C_BOT='\033[38;5;124m'
# Shadow/Feet: Very Dark Red
C_SHD='\033[38;5;88m'
# Gray for haiku text
GRAY="\033[90m"
# Reset
NC='\033[0m'

# --- The Logo ---
# Style: Varsity/Block with heavy stroke
# Text: BASHOBOT

printf "${C_TOP}██████╗  █████╗ ███████╗██╗  ██╗ ██████╗ ██████╗  ██████╗ ████████╗${NC}\n"
printf "${C_MID1}██╔══██╗██╔══██╗██╔════╝██║  ██║██╔═══██╗██╔══██╗██╔═══██╗╚══██╔══╝${NC}\n"
printf "${C_MID2}██████╔╝███████║███████╗███████║██║   ██║██████╔╝██║   ██║   ██║   ${NC}\n"
printf "${C_MID2}██╔══██╗██╔══██║╚════██║██╔══██║██║   ██║██╔══██╗██║   ██║   ██║   ${NC}\n"
printf "${C_BOT}██████╔╝██║  ██║███████║██║  ██║╚██████╔╝██████╔╝╚██████╔╝   ██║   ${NC}\n"
printf "${C_SHD}╚═════╝ ╚═╝  ╚═╝╚══════╝╚═╝  ╚═╝ ╚═════╝ ╚═════╝  ╚═════╝    ╚═╝   ${NC}\n"

# Optional: Add a subtle retro "scanline" or shine effect description below
# echo -e "${C_TOP}      The Crustacean Shell Automaton      ${NC}"


line=$(cat <<'EOF' | awk 'BEGIN{srand()} rand()<1/NR{line=$0} END{print line}'
Terminal glows red // Lobster clicks the wrong option // Life segfaults again
In boiling water // Lobster learns impermanence // Press any key now
Sideways I scuttle // Like my goals, misaligned // Yet still moving on
Shell cracked, prompt appears // Are you sure asks the system // Existence says yes
Cursor blinks slowly // Lobster waits for meaning // Timeout exceeded
Molting season comes // Even crustaceans reboot // Same bugs, new shell
Claws up, facing life // I pinch what I control // Mostly nothing though
Deep sea dark screen space // Lobster types with many legs // Hits backspace twice
Log file full of sand // Warnings smell faintly of salt // Works fine in prod
ASCII lobster dreams // Of a stack without limits // Heap overflowed
EOF
)

printf "${GRAY}${line}${NC}\n"


