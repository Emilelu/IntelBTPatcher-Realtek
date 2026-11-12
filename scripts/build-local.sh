#!/bin/zsh
#
# build-local.sh -- build IntelBTPatcher on a Mac without Xcode.
#
# GitHub Actions macOS runners can sit in the queue for a long time, and a
# Command Line Tools install has no xcodebuild.  This script reproduces the
# kext locally with clang + MacKernelSDK + Lilu headers.
#
#   ./scripts/build-local.sh [VERSION]     # default 2.6.0
#
# Layout it expects (all cloned next to this repo, or set the env vars):
#   btbuild/
#     MacKernelSDK/          https://github.com/acidanthera/MacKernelSDK
#     Lilu/                  https://github.com/acidanthera/Lilu
#     RealtekBTPatcher/      this repo
#
# Output: out/IntelBTPatcher.kext  (ready to drop into EFI/OC/Kexts)
#
set -e

VER=${1:-2.6.0}
HERE=${0:A:h}
REPO=${HERE:h}
ROOT=${IBTP_BUILD_ROOT:-${REPO:h}}
SDK=${ROOT}/MacKernelSDK
LILU=${ROOT}/Lilu
OUT=${REPO}/out
KEXT=${OUT}/IntelBTPatcher.kext
STUB=${OUT}/sdkstub

if [ ! -d "${SDK}/Headers" ]; then
	echo "MacKernelSDK not found at ${SDK}" >&2
	exit 1
fi
if [ ! -f "${LILU}/Lilu/Headers/kern_api.hpp" ]; then
	echo "Lilu not found at ${LILU}" >&2
	exit 1
fi

# MacKernelSDK ships Apple's TargetConditionals.h, which reports
# TARGET_OS_OSX == 1 on macOS.  IOKit/usb/IOUSBHostPipe.h and
# IOKit/usb/IOUSBHostDevice.h use that macro to also pull in the DriverKit
# variants of the same classes, so a raw clang build dies with
#   redefinition of 'IOUSBHostPipe'
#   redefinition of 'IOUSBHostDevice'
#   unknown type name 'IOUSBHostPipe_Methods'
# A kext must see TARGET_OS_OSX == 0, so shadow the header with a copy whose
# macOS branch is flipped.  (This is what the Xcode KEXT product type ends up
# doing implicitly.)
rm -rf "${OUT}"
mkdir -p "${OUT}" "${STUB}"
sed 's/#define TARGET_OS_OSX               1/#define TARGET_OS_OSX               0/' \
	"${SDK}/Headers/TargetConditionals.h" > "${STUB}/TargetConditionals.h"

CXXFLAGS=(
	-target x86_64-apple-macos10.15
	-std=gnu++14
	-fno-rtti -fno-exceptions -fno-common
	-fapple-kext -mkernel
	-nostdinc++
	-I "${STUB}"
	-I "${SDK}/Headers"
	-I "${SDK}/Headers/libkern"
	-I "${LILU}/Lilu"
	-D__ACIDANTHERA_MAC_SDK=2600
	-DPRODUCT_NAME=IntelBTPatcher
	-DMODULE_VERSION=${VER}
	-O2
	-Wno-everything
)

echo "== compiling IntelBTPatcher.cpp =="
clang++ "${CXXFLAGS[@]}" -c "${REPO}/IntelBTPatcher/IntelBTPatcher.cpp" -o "${OUT}/IntelBTPatcher.o"

echo "== compiling Lilu plugin_start.cpp =="
clang++ "${CXXFLAGS[@]}" -c "${LILU}/Lilu/Library/plugin_start.cpp" -o "${OUT}/plugin_start.o"

echo "== linking =="
clang++ -target x86_64-apple-macos10.15 -mkernel -nostdlib \
	-Wl,-kext -Wl,-undefined,dynamic_lookup \
	-L "${SDK}/Library/x86_64" \
	"${OUT}/IntelBTPatcher.o" "${OUT}/plugin_start.o" \
	-lkmod -o "${OUT}/IntelBTPatcher"

echo "== assembling ${KEXT} =="
mkdir -p "${KEXT}/Contents/MacOS"
cp "${OUT}/IntelBTPatcher" "${KEXT}/Contents/MacOS/IntelBTPatcher"

VER="${VER}" python3 - "${REPO}/IntelBTPatcher/Info.plist" "${KEXT}/Contents/Info.plist" <<'PY'
import os
import sys

src, dst = sys.argv[1], sys.argv[2]
ver = os.environ["VER"]
text = open(src).read()
for placeholder, value in {
    "$(DEVELOPMENT_LANGUAGE)": "en",
    "$(EXECUTABLE_NAME)": "IntelBTPatcher",
    "$(PRODUCT_BUNDLE_IDENTIFIER)": "com.zxystd.IntelBTPatcher",
    "$(PRODUCT_NAME:rfc1034identifier)": "IntelBTPatcher",
    "$(PRODUCT_NAME)": "IntelBTPatcher",
    "$(PRODUCT_BUNDLE_PACKAGE_TYPE)": "KEXT",
    "$(MARKETING_VERSION)": ver,
    "$(CURRENT_PROJECT_VERSION)": ver,
}.items():
    text = text.replace(placeholder, value)
assert "$(" not in text, "unsubstituted build-setting placeholder in Info.plist"
open(dst, "w").write(text)
PY

echo "== verify =="
shasum -a 256 "${KEXT}/Contents/MacOS/IntelBTPatcher"
plutil -p "${KEXT}/Contents/Info.plist" | grep CFBundleVersion
# The baked-in VersionInfo string proves MODULE_VERSION reached the compiler:
# REL-<maj><min><patch>-<build date>
python3 - "${KEXT}/Contents/MacOS/IntelBTPatcher" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
hit = data.find(b"REL-")
print("VersionInfo:", data[hit:hit + 21].split(b"\0")[0].decode() if hit >= 0 else "MISSING")
PY
echo "done: ${KEXT}"
