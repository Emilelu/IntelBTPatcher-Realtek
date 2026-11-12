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

# ld64 used to synthesise three things whenever -kext was passed: the writable
# __kmod_info symbol, plus the __realmain/__antimain indirections that libkmod's
# c_start.o / c_stop.o jump through.  The linker shipped with macOS 26
# (ld-1267) dropped that synthesis, so a locally linked kext is rejected with
#   cannot be placed in kernel collection because: kexts must have a
#   _kmod_info symbol
# Xcode-built binaries still get it from the older toolchain, which is why only
# the local build broke.  Reproduce the structure by hand: layout and initial
# values match what the old linker emitted (next=0, info_version=1, id=-1,
# reference_count=-1), and the start/stop slots point straight at the
# PRODUCT_NAME_kern_start / _kern_stop entry points that Lilu's
# plugin_start.cpp exports.
cat > "${OUT}/kmod_info.cpp" <<EOF
#include <mach/kmod.h>

extern "C" kern_return_t IntelBTPatcher_kern_start(kmod_info_t *, void *);
extern "C" kern_return_t IntelBTPatcher_kern_stop(kmod_info_t *, void *);

extern "C" {
kmod_info_t kmod_info __attribute__((used, section("__DATA,__data"))) = {
	nullptr,
	KMOD_INFO_VERSION,
	(uint32_t)-1,
	{"com.zxystd.IntelBTPatcher"},
	{"${VER}"},
	-1,
	nullptr,
	0,
	0,
	0,
	reinterpret_cast<kmod_start_func_t *>(&IntelBTPatcher_kern_start),
	reinterpret_cast<kmod_stop_func_t *>(&IntelBTPatcher_kern_stop),
};
}
EOF

echo "== compiling kmod_info stub =="
clang++ "${CXXFLAGS[@]}" -c "${OUT}/kmod_info.cpp" -o "${OUT}/kmod_info.o"

echo "== compiling IntelBTPatcher.cpp =="
clang++ "${CXXFLAGS[@]}" -c "${REPO}/IntelBTPatcher/IntelBTPatcher.cpp" -o "${OUT}/IntelBTPatcher.o"

echo "== compiling Lilu plugin_start.cpp =="
clang++ "${CXXFLAGS[@]}" -c "${LILU}/Lilu/Library/plugin_start.cpp" -o "${OUT}/plugin_start.o"

echo "== linking =="
clang++ -target x86_64-apple-macos10.15 -mkernel -nostdlib \
	-Wl,-kext -Wl,-undefined,dynamic_lookup \
	-L "${SDK}/Library/x86_64" \
	"${OUT}/IntelBTPatcher.o" "${OUT}/plugin_start.o" "${OUT}/kmod_info.o" \
	-lkmod -o "${OUT}/IntelBTPatcher"

echo "== assembling ${KEXT} =="
mkdir -p "${KEXT}/Contents/MacOS"
cp "${OUT}/IntelBTPatcher" "${KEXT}/Contents/MacOS/IntelBTPatcher"

VER="${VER}" python3 - "${REPO}/IntelBTPatcher/Info.plist" "${KEXT}/Contents/Info.plist" <<'PY'
import os
import plistlib
import sys

src, dst = sys.argv[1], sys.argv[2]
ver = os.environ["VER"]

with open(src, "rb") as f:
    info = plistlib.load(f)

SUBSTS = {
    "$(DEVELOPMENT_LANGUAGE)": "en",
    "$(EXECUTABLE_NAME)": "IntelBTPatcher",
    "$(PRODUCT_BUNDLE_IDENTIFIER)": "com.zxystd.IntelBTPatcher",
    "$(PRODUCT_NAME:rfc1034identifier)": "IntelBTPatcher",
    "$(PRODUCT_NAME)": "IntelBTPatcher",
    "$(PRODUCT_BUNDLE_PACKAGE_TYPE)": "KEXT",
    "$(MARKETING_VERSION)": ver,
    "$(CURRENT_PROJECT_VERSION)": ver,
}

def fix(value):
    if isinstance(value, str):
        for placeholder, replacement in SUBSTS.items():
            value = value.replace(placeholder, replacement)
        assert "$(" not in value, f"unsubstituted build-setting placeholder: {value}"
        return value
    if isinstance(value, dict):
        return {fix(k): fix(v) for k, v in value.items()}
    if isinstance(value, list):
        return [fix(v) for v in value]
    return value

info = fix(info)

# Xcode's ProcessInfoPlistFile injects these from the target's build settings.
# A kext without CFBundleSupportedPlatforms is rejected while the boot kext
# collection is built, so the local script has to add them itself.
info.update({
    "CFBundleVersion": ver,
    "CFBundleShortVersionString": ver,
    "CFBundleSupportedPlatforms": ["MacOSX"],
    "LSMinimumSystemVersion": "10.12",
    "DTPlatformName": "macosx",
    "DTCompiler": "com.apple.compilers.llvm.clang.1_0",
    "CFBundlePackageType": "KEXT",
})

with open(dst, "wb") as f:
    plistlib.dump(info, f)
PY

echo "== verify =="
shasum -a 256 "${KEXT}/Contents/MacOS/IntelBTPatcher"
plutil -p "${KEXT}/Contents/Info.plist" | grep CFBundleVersion
# The kernel refuses a kext without _kmod_info, and OpenCore then skips it
# silently, so fail the build instead of shipping an unloadable bundle.
nm "${KEXT}/Contents/MacOS/IntelBTPatcher" | grep -q ' _kmod_info$' \
	|| { echo "FATAL: _kmod_info missing -- kext would never load" >&2; exit 1; }
plutil -p "${KEXT}/Contents/Info.plist" | grep -q CFBundleSupportedPlatforms \
	|| { echo "FATAL: CFBundleSupportedPlatforms missing" >&2; exit 1; }
# The baked-in VersionInfo string proves MODULE_VERSION reached the compiler:
# REL-<maj><min><patch>-<build date>
python3 - "${KEXT}/Contents/MacOS/IntelBTPatcher" <<'PY'
import sys
data = open(sys.argv[1], "rb").read()
hit = data.find(b"REL-")
print("VersionInfo:", data[hit:hit + 21].split(b"\0")[0].decode() if hit >= 0 else "MISSING")
PY
echo "done: ${KEXT}"
