#!/usr/bin/env bash
# This script is for weekly differential builds ONLY and is independent of build.sh
set -e

# --- Read configuration from environment variables ---
MAIN_DEFCONFIG="${PROJECT_DEFCONFIG:?PROJECT_DEFCONFIG is not set}"
LOCALVERSION_BASE="${PROJECT_LOCALVERSION_BASE:?PROJECT_LOCALVERSION_BASE is not set}"
LTO="${PROJECT_LTO}"
TOOLCHAIN_PATH_PREFIX="${PROJECT_TOOLCHAIN_PATH_PREFIX:?PROJECT_TOOLCHAIN_PATH_PREFIX is not set}"
TOOLCHAIN_PATH_EXPORTS_JSON="${PROJECT_TOOLCHAIN_PATH_EXPORTS:?PROJECT_TOOLCHAIN_PATH_EXPORTS is not set}"
ZIP_NAME_PREFIX="${PROJECT_ZIP_NAME_PREFIX:?PROJECT_ZIP_NAME_PREFIX is not set}"
GITHUB_REPO="${PROJECT_REPO:?PROJECT_REPO is not set}"
VERSION_METHOD="${PROJECT_VERSION_METHOD:-param}"
EXTRA_HOST_ENV="${PROJECT_EXTRA_HOST_ENV:-false}"
DISABLE_SECURITY_JSON="${PROJECT_DISABLE_SECURITY:-[]}"
SUPPORTED_KSU_BRANCHES_JSON="${PROJECT_SUPPORTED_KSU:?PROJECT_SUPPORTED_KSU is not set}"
PROJECT_KEY="${PROJECT_KEY:?PROJECT_KEY is not set}"

# --- Script start ---
# The script's working directory is 'kernel_repo'. All paths will be relative to this.
TOOLCHAIN_BASE_PATH=$(realpath "../toolchain/${TOOLCHAIN_PATH_PREFIX}")

# --- Setup Toolchain Environment ---
echo "--- Setting up toolchain environment for weekly build ---"
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
if [[ "$ZIP_NAME_PREFIX" == "Z3_Kernel" ]]; then KERNEL_LLVM_BIN=$TOOLCHAIN_BASE_PATH/clang/host/linux-x86/clang-r416183b/bin; BUILD_CROSS_COMPILE=$TOOLCHAIN_BASE_PATH/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8/x86_64-linux/bin; CLANG_TRIPLE=aarch64-linux-gnu-; MAKE_ARGS+=" SUBARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- REAL_CC=$KERNEL_LLVM_BIN CLANG_TRIPLE=$CLANG_TRIPLE CONFIG_SECTION_MISMATCH_WARN_ONLY=y "; fi

# --- Reusable Compilation Function ---
compile_kernel_for_branch() {
    local branch_name=$1
    local version_suffix=$2
    echo -e "\n\n--- Starting compilation for branch: $branch_name ($version_suffix) ---"
    git checkout "$branch_name" && git pull

    # --- NEW: Setup KernelSU based on branch ---
    echo "--- Setting up KernelSU for branch: $branch_name ---"
    if [[ "$branch_name" == "sukisuultra" ]]; then
      if [[ "$PROJECT_KEY" == "z3_sm8350" ]]; then
        echo "--- Detected z3_sm8350 on sukisuultra branch, using SukiSU fork with version susfs-1.5.7 ---"
        curl -LSs "https://raw.githubusercontent.com/Prslc/SukiSU-Ultra/main/kernel/setup.sh" | bash -s susfs-1.5.7
      else
        echo "--- Using standard SukiSU-Ultra setup ---"
        curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s susfs-main
      fi
    elif [[ "$branch_name" == "mksu" ]]; then
      curl -LSs "https://raw.githubusercontent.com/5ec1cff/KernelSU/main/kernel/setup.sh" | bash -
    elif [[ "$branch_name" == "ksu" ]]; then
      curl -LSs "https://raw.githubusercontent.com/tiann/KernelSU/main/kernel/setup.sh" | bash -
    else
      echo "--- Branch is '$branch_name', skipping KernelSU setup. ---"
    fi
    # --- END KernelSU Setup ---

    rm -rf out
    make ${MAKE_ARGS} "$MAIN_DEFCONFIG"
    
    local disable_flags="-d UH -d RKP -d KDP -d SECURITY_DEFEX -d INTEGRITY -d FIVE -d TRIM_UNUSED_KSYMS"
    for flag in $(echo "$DISABLE_SECURITY_JSON" | jq -r '.[]'); do disable_flags+=" -d $flag"; done
    ./scripts/config --file out/.config $disable_flags
    if [ "$LTO" = "thin" ]; then ./scripts/config --file out/.config -e LTO_CLANG_THIN -d LTO_CLANG_FULL; elif [ "$LTO" = "full" ]; then ./scripts/config --file out/.config -e LTO_CLANG_FULL -d LTO_CLANG_THIN; else ./scripts/config --file out/.config -d LTO_CLANG_THIN -d LTO_CLANG_FULL; fi

    local final_localversion="${LOCALVERSION_BASE}-${version_suffix}"
    local make_args_build="${MAKE_ARGS} LOCALVERSION=${final_localversion}"
    export KBUILD_BUILD_TIMESTAMP=$(TZ='Asia/Hong_Kong' date +"%a %b %d %H:%M:%S %Z %Y")
    
    echo "--- Compiling kernel (-j$(nproc)) for $version_suffix ---"
    make -j$(nproc) ${make_args_build}
    if [ ${PIPESTATUS[0]} -ne 0 ]; then echo "--- Kernel compilation failed for $version_suffix! ---"; exit 1; fi
    echo -e "\n--- Kernel compilation successful for $version_suffix! ---\n"

    local DO_PATCH_LINUX=false
    if [[ "$branch_name" == "sukisuultra" ]]; then
        if [[ "$PROJECT_KEY" == "s24_sm8650" || "$PROJECT_KEY" == "s25_sm8750" || "$PROJECT_KEY" == "tabs10_mt6989" || "$PROJECT_KEY" == "s25e_sm8750" || "$PROJECT_KEY" == "s24fe_s5e9945" ]]; then
            DO_PATCH_LINUX=true
        fi
    fi

    if [[ "$DO_PATCH_LINUX" == "true" ]]; then
        echo "--- Applying SukiSU-Ultra specific patch_linux for ${PROJECT_KEY} ---"
        cp ../anykernel_patcher_repo/patch_linux ./out/arch/arm64/boot/
        (cd ./out/arch/arm64/boot/ && chmod +x ./patch_linux && ./patch_linux && mv -f oImage Image)
        echo "--- patch_linux applied successfully. ---"
    fi

    cp out/arch/arm64/boot/Image "../Image_${version_suffix}"
}

# --- Main Logic ---
BASE_BRANCH=""
BASE_SUFFIX=""
OTHER_BRANCHES=()
SUPPORTED_BRANCHES=($(echo "$SUPPORTED_KSU_BRANCHES_JSON" | jq -r '.[]'))

if git rev-parse --verify main >/dev/null 2>&1; then
    echo "--- 'main' branch found. Using LKM as base. ---"
    BASE_BRANCH="main"
    BASE_SUFFIX="LKM"
    OTHER_BRANCHES=("${SUPPORTED_BRANCHES[@]}")
else
    echo "--- 'main' branch not found. Using first supported KSU as base. ---"
    BASE_BRANCH="${SUPPORTED_BRANCHES[0]}"
    BASE_SUFFIX=$(echo "$BASE_BRANCH" | tr '[:lower:]' '[:upper:]' | sed 's/SUKI SUULTRA/SukiSUU/')
    for i in "${!SUPPORTED_BRANCHES[@]}"; do
      if [ $i -ne 0 ]; then OTHER_BRANCHES+=("${SUPPORTED_BRANCHES[$i]}"); fi
    done
fi

compile_kernel_for_branch "$BASE_BRANCH" "$BASE_SUFFIX"
mv "../Image_${BASE_SUFFIX}" "../Image_Base"

for branch in "${OTHER_BRANCHES[@]}"; do
    suffix=$(echo "$branch" | tr '[:lower:]' '[:upper:]' | sed 's/SUKI SUULTRA/SukiSUU/')
    compile_kernel_for_branch "$branch" "$suffix"
done

echo "--- Creating bsdiff patches ---"
pip install bsdiff4
mkdir -p ../patches
for branch in "${OTHER_BRANCHES[@]}"; do
    suffix=$(echo "$branch" | tr '[:lower:]' '[:upper:]' | sed 's/SUKI SUULTRA/SukiSUU/')
    echo "Creating patch for $suffix..."
    python3 ../central_repo/scripts/bsdiff4_create.py "../Image_Base" "../Image_${suffix}" "../patches/${branch}.p"
done
echo "--- Patches created successfully ---"

echo "--- Preparing AnyKernel3 Patcher package ---"
mv ../Image_Base ../anykernel_patcher_repo/Image
echo "$BASE_SUFFIX" > ../anykernel_patcher_repo/base_kernel_name
if [ ${#OTHER_BRANCHES[@]} -gt 0 ]; then
    mv ../patches/* ../anykernel_patcher_repo/bs_patches/
fi

cd ../anykernel_patcher_repo
kernel_release=$(grep -oP 'UTS_RELEASE "\K[^"]+' ../kernel_repo/out/include/generated/compile.h)
final_name="${ZIP_NAME_PREFIX}_${kernel_release}_Weekly-Patch-Kit_$(TZ='Asia/Hong_Kong' date '+%Y%m%d')"
zip -r9 "../${final_name}.zip" . -x "*.zip" README.md LICENSE '.*' '*/.*'
cd ..
UPLOAD_FILE_PATH=$(realpath "${final_name}.zip")

echo -e "\n--- Publishing to GitHub Release ---"
TAG="weekly-release-$(TZ='Asia/Hong_Kong' date +%Y%m%d-%H%M)"
RELEASE_TITLE="周常更新 - ${kernel_release} (多合一差分包 | $(TZ='Asia/Hong_Kong' date +'%Y-%m-%d'))"
RELEASE_NOTES="由 CI 在 $(TZ='Asia/Hong_Kong' date) 自动构建的周常差分更新包。刷入时可在 Recovery 中选择需要的内核版本。"
gh release create "$TAG" "$UPLOAD_FILE_PATH" --repo "$GITHUB_REPO" --title "$RELEASE_TITLE" --notes "$RELEASE_NOTES" --target "$BASE_BRANCH"
