#!/usr/bin/env bash
# This script compiles a SINGLE branch and is called by the parallel workflow.
set -e

# --- Read configuration from environment variables ---
BRANCH_NAME="${BRANCH_NAME:?BRANCH_NAME is not set}"
VERSION_SUFFIX="${VERSION_SUFFIX:?VERSION_SUFFIX is not set}"
MAIN_DEFCONFIG="${PROJECT_DEFCONFIG:?PROJECT_DEFCONFIG is not set}"
LOCALVERSION_BASE="${PROJECT_LOCALVERSION_BASE:?PROJECT_LOCALVERSION_BASE is not set}"
LTO="${PROJECT_LTO}"
TOOLCHAIN_PATH_PREFIX="${PROJECT_TOOLCHAIN_PATH_PREFIX:?PROJECT_TOOLCHAIN_PATH_PREFIX is not set}"
TOOLCHAIN_PATH_EXPORTS_JSON="${PROJECT_TOOLCHAIN_PATH_EXPORTS:?PROJECT_TOOLCHAIN_PATH_EXPORTS is not set}"
PROJECT_KEY="${PROJECT_KEY:?PROJECT_KEY is not set}"
VERSION_METHOD="${PROJECT_VERSION_METHOD:-param}"
EXTRA_HOST_ENV="${PROJECT_EXTRA_HOST_ENV:-false}"
DISABLE_SECURITY_JSON="${PROJECT_DISABLE_SECURITY:-[]}"

# --- Script start ---
TOOLCHAIN_BASE_PATH=$(realpath "../toolchain/${TOOLCHAIN_PATH_PREFIX}")

# --- Setup Toolchain Environment ---
echo "--- Setting up toolchain for branch: $BRANCH_NAME ---"
for path_suffix in $(echo "$TOOLCHAIN_PATH_EXPORTS_JSON" | jq -r '.[]'); do
  export PATH="$TOOLCHAIN_BASE_PATH/$path_suffix:$PATH"
done
if [ "$EXTRA_HOST_ENV" == "true" ]; then
    LLD_COMPILER_RT="-fuse-ld=lld --rtlib=compiler-rt"
    sysroot_flags+="--sysroot=$TOOLCHAIN_BASE_PATH/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8/sysroot "
    cflags+="-I$TOOLCHAIN_BASE_PATH/kernel-build-tools/linux-x86/include "
    ldflags+="-L $TOOLCHAIN_BASE_PATH/kernel-build-tools/linux-x86/lib64 "
    ldflags+=${LLD_COMPILER_RT}
    export LD_LIBRARY_PATH="$TOOLCHAIN_BASE_PATH/kernel-build-tools/linux-x86/lib64"
    export HOSTCFLAGS="$sysroot_flags $cflags"
    export HOSTLDFLAGS="$sysroot_flags $ldflags"
fi

# --- Core Compilation Arguments ---
TARGET_SOC_NAME=$(echo "$PROJECT_KEY" | cut -d'_' -f2)
MAKE_ARGS="O=out ARCH=arm64 CC=clang LLVM=1 LLVM_IAS=1"
MAKE_ARGS="CCACHE=ccache ${MAKE_ARGS} TARGET_SOC=${TARGET_SOC_NAME}"
if [[ "$ZIP_NAME_PREFIX" == "Z4_Kernel" ]]; then MAKE_ARGS+=" SUBARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-"; fi
if [[ "$PROJECT_KEY" == "z3_sm8350" ]]; then KERNEL_LLVM_BIN=$TOOLCHAIN_BASE_PATH/clang/host/linux-x86/clang-r416183b/bin; BUILD_CROSS_COMPILE=$TOOLCHAIN_BASE_PATH/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8/x86_64-linux/bin; CLANG_TRIPLE=aarch64-linux-gnu-; MAKE_ARGS+=" SUBARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- REAL_CC=$KERNEL_LLVM_BIN CLANG_TRIPLE=$CLANG_TRIPLE CONFIG_SECTION_MISMATCH_WARN_ONLY=y "; fi

# --- Main Compilation Logic ---
echo "--- Setting up KernelSU for branch: $BRANCH_NAME ---"
if [[ "$BRANCH_NAME" == "sukisuultra" ]]; then
  if [[ "$PROJECT_KEY" == "z3_sm8350" ]]; then
    echo "--- Detected z3_sm8550 on sukisuultra branch, using SukiSU fork with version susfs-1.5.7 ---"
    curl -LSs "https://raw.githubusercontent.com/Prslc/SukiSU-Ultra/main/kernel/setup.sh" | bash -s susfs-1.5.7
  else
    echo "--- Using standard SukiSU-Ultra setup ---"
    curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s susfs-main
  fi
elif [[ "$BRANCH_NAME" == "mksu" ]]; then
  curl -LSs "https://raw.githubusercontent.com/5ec1cff/KernelSU/main/kernel/setup.sh" | bash -
elif [[ "$BRANCH_NAME" == "ksu" ]]; then
  curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -
else
  echo "--- Branch is '$BRANCH_NAME', skipping KernelSU setup. ---"
fi

rm -rf out
make ${MAKE_ARGS} "$MAIN_DEFCONFIG"

local disable_flags="-d UH -d RKP -d KDP -d SECURITY_DEFEX -d INTEGRITY -d FIVE -d TRIM_UNUSED_KSYMS"
for flag in $(echo "$DISABLE_SECURITY_JSON" | jq -r '.[]'); do disable_flags+=" -d $flag"; done
./scripts/config --file out/.config $disable_flags
if [ "$LTO" = "thin" ]; then ./scripts/config --file out/.config -e LTO_CLANG_THIN -d LTO_CLANG_FULL; elif [ "$LTO" = "full" ]; then ./scripts/config --file out/.config -e LTO_CLANG_FULL -d LTO_CLANG_THIN; else ./scripts/config --file out/.config -d LTO_CLANG_THIN -d LTO_CLANG_FULL; fi

local final_localversion="${LOCALVERSION_BASE}-${VERSION_SUFFIX}"
local make_args_build="${MAKE_ARGS} LOCALVERSION=${final_localversion}"
export KBUILD_BUILD_TIMESTAMP=$(TZ='Asia/Hong_Kong' date +"%a %b %d %H:%M:%S %Z %Y")

echo "--- Compiling kernel (-j$(nproc)) for $VERSION_SUFFIX ---"
make -j$(nproc) ${make_args_build}
if [ ${PIPESTATUS[0]} -ne 0 ]; then echo "--- Kernel compilation failed for $VERSION_SUFFIX! ---"; exit 1; fi
echo -e "\n--- Kernel compilation successful for $VERSION_SUFFIX! ---\n"

local DO_PATCH_LINUX=false
if [[ "$BRANCH_NAME" == "sukisuultra" ]]; then
    if [[ "$PROJECT_KEY" == "s24_sm8650" || "$PROJECT_KEY" == "s25_sm8750" || "$PROJECT_KEY" == "tabs10_mt6989" || "$PROJECT_KEY" == "s25e_sm8750" || "$PROJECT_KEY" == "s24fe_s5e9945" ]]; then
        DO_PATCH_LINUX=true
    fi
fi

if [[ "$DO_PATCH_LINUX" == "true" ]]; then
    echo "--- Applying SukiSU-Ultra specific patch_linux for ${PROJECT_KEY} ---"
    # We can't get this from AnyKernel repo here, so it must exist in the kernel source repo
    if [ -f "./patch_linux" ]; then
        chmod +x ./patch_linux && ./patch_linux && mv -f oImage out/arch/arm64/boot/Image
        echo "--- patch_linux applied successfully. ---"
    else
        echo "--- WARNING: patch_linux script not found in kernel source root! ---"
    fi
fi

# Output the final image to the workspace root for artifact upload
cp out/arch/arm64/boot/Image "../Image_${VERSION_SUFFIX}"
