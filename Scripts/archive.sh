#!/bin/zsh
# Archives Hub for the Mac as it ships: Release, with the v57 apps' size settings, into Xcode's Archives folder so
# Organizer distributes it (Window > Organizer > Distribute App) like an archive from Product > Archive.
#
# The size settings are Code's xcodebuild-release (xcodebuild with Swift LTO, ld-archive-prelink as the linker and
# actool-icon-slim for the icon): Xcode pre-links each Swift package target into one relocatable object (`ld -r`)
# that keeps everything in the app, used or not; the wrapper writes a static archive instead, so the final link
# drops unused package code, then runs LLVM's machine outliner and swift-record-gc on that link. It comes from
# ~/Developer/v57/Code (RELEASE_TOOLS: another copy of Code's Sources/CodeActions/Release). The arm64 Hub executable goes from 14.8 MB
# (plain Release) to 8.2 MB.
#
# Usage: Scripts/archive.sh [-l] [-d <DerivedData>] [-o <archive path>]
#   -l  build against the sibling checkouts (Hub-Local.xcworkspace) instead of the packages on GitHub
#   -d  DerivedData folder (default: Xcode's)
#   -o  where the .xcarchive goes (default: ~/Library/Developer/Xcode/Archives/<date>/Hub <date time>.xcarchive)
set -euo pipefail

root=${0:A:h:h}
container=(-project $root/Hub.xcodeproj)
derived=()
archive=$HOME/Library/Developer/Xcode/Archives/$(date +%Y-%m-%d)/"Hub $(date '+%-d.%m.%y, %H.%M').xcarchive"
while getopts ld:o: opt; do
  case $opt in
    l) container=(-workspace $root/Hub-Local.xcworkspace) ;;
    d) derived=(-derivedDataPath ${OPTARG:A}) ;;
    o) archive=${OPTARG:A} ;;
    *) sed -n 11,14p $0 >&2; exit 64 ;;
  esac
done

release=${RELEASE_TOOLS:-$HOME/Developer/v57/Code/Sources/CodeActions/Release}/xcodebuild-release
[[ -x $release ]] || { echo "xcodebuild-release not found at $release (RELEASE_TOOLS: Code's Sources/CodeActions/Release)" >&2; exit 1 }

log=${TMPDIR:-/tmp}/hub-archive-$$.log
mkdir -p ${archive:h}
echo "Archiving to $archive (log: $log)"
$release archive $container -scheme Hub -configuration Release -destination 'generic/platform=macOS' \
  $derived -archivePath $archive > $log 2>&1 || { grep -E 'error:' $log | head -20 >&2; echo "archive failed, see $log" >&2; exit 1 }

app=$archive/Products/Applications/Hub.app
codesign --verify --strict --deep $app
for exe in $app/Contents/MacOS/Hub $app/Contents/PlugIns/PacketTunnelExtension.appex/Contents/MacOS/PacketTunnelExtension; do
  thin=$(mktemp)
  lipo -thin arm64 $exe -output $thin 2>/dev/null || cp $exe $thin
  echo "${exe:t}: $(( $(stat -f %z $thin) / 1000 )) KB arm64"
  rm -f $thin
done
