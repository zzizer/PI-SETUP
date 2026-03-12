#!/bin/bash

set -e

# ── Colours ───────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'
 
log()     { echo -e "   ${GREEN}✔${NC}  $1"; }
info()    { echo -e "   ${BLUE}→${NC}  $1"; }
skip()    { echo -e "   ${DIM}✔  $1 (already done)${NC}"; }
warn()    { echo -e "   ${YELLOW}!${NC}  $1"; }
error()   { echo -e "   ${RED}✘${NC}  $1"; exit 1; }
section() { echo -e "\n${CYAN}${BOLD}── $1${NC}"; }

echo "SETTING UP. This may take a while..."