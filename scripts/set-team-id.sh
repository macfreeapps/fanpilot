#!/bin/zsh
# Re-sign FanPilot for your own Apple Developer team.
#
# The privileged helper only accepts connections from an app signed by the same team, so the Team ID is
# written in a few places. This script replaces the current one everywhere and regenerates the project.
#
#   scripts/set-team-id.sh ABCDE12345
#
# Find your Team ID in Xcode > Settings > Accounts, or at developer.apple.com > Membership.
set -e
NEW="$1"
if [[ ! "$NEW" =~ '^[A-Z0-9]{10}$' ]]; then echo "Usage: $0 <10-character Apple Team ID>"; exit 64; fi
cd "$(dirname "$0")/.."
OLD=$(grep -m1 'DEVELOPMENT_TEAM:' project.yml | awk '{print $2}')
[[ -n "$OLD" ]] || { echo "Could not find the current Team ID in project.yml"; exit 1 }
echo "Replacing $OLD with $NEW"
FILES=(project.yml FanPilot/HelperInstaller.swift FanPilotHelper/RootHelperService.swift)
for f in $FILES; do sed -i '' "s/$OLD/$NEW/g" "$f"; done
command -v xcodegen >/dev/null && xcodegen generate || echo "Install XcodeGen (brew install xcodegen) and run: xcodegen generate"
echo "Done. Build with the 'Apple Development' certificate for team $NEW."
