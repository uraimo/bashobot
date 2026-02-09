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