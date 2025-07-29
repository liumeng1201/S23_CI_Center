#!/usr/bin/env bash
set -e

# --- 从环境变量读取配置 ---
MAIN_DEFCONFIG="${PROJECT_DEFCONFIG:?PROJECT_DEFCONFIG 未设置}"
LOCALVERSION_BASE="${PROJECT_LOCALVERSION_BASE:?PROJECT_LOCALVERSION_BASE 未设置}"
LTO="${PROJECT_LTO}"
TOOLCHAIN_PATH_PREFIX="${PROJECT_TOOLCHAIN_PATH_PREFIX:?PROJECT_TOOLCHAIN_PATH_PREFIX 未设置}"
TOOLCHAIN_PATH_EXPORTS_JSON="${PROJECT_TOOLCHAIN_PATH_EXPORTS:?PROJECT_TOOLCHAIN_PATH_EXPORTS 未设置}"
ANYKERNEL_REPO="${PROJECT_ANYKERNEL_REPO:?PROJECT_ANYKERNEL_REPO 未设置}"
ANYKERNEL_BRANCH="${PROJECT_ANYKERNEL_BRANCH:?PROJECT_ANYKERNEL_BRANCH 未设置}"
ZIP_NAME_PREFIX="${PROJECT_ZIP_NAME_PREFIX:?PROJECT_ZIP_NAME_PREFIX 未设置}"
GITHUB_REPO="${PROJECT_REPO:?PROJECT_REPO 未设置}"
AUTO_RELEASE="${DO_RELEASE:?DO_RELEASE 未设置}"
IS_PRERELEASE="${IS_PRERELEASE_INPUT:?IS_PRERELEASE_INPUT 未设置}"
VERSION_METHOD="${PROJECT_VERSION_METHOD:-param}"
EXTRA_HOST_ENV="${PROJECT_EXTRA_HOST_ENV:-false}"
DISABLE_SECURITY_JSON="${PROJECT_DISABLE_SECURITY:-[]}"

# --- 动态决定是否运行 patch_linux ---
DO_PATCH_LINUX=false
if [[ "$BRANCH_NAME" == "sukisuultra" ]]; then
  if [[ "$PROJECT_KEY" == "s24_sm8650" || "$PROJECT_KEY" == "s25_sm8750" || "$PROJECT_KEY" == "tabs10_mt6989" ]]; then
    DO_PATCH_LINUX=true
  fi
fi

# --- 脚本开始 ---
cd "$(dirname "$0")"
TOOLCHAIN_BASE_PATH=$(realpath "./toolchain/${TOOLCHAIN_PATH_PREFIX}")

# --- 动态设置工具链环境 ---
echo "--- 正在设置动态工具链环境 ---"
for path_suffix in $(echo "$TOOLCHAIN_PATH_EXPORTS_JSON" | jq -r '.[]'); do
  export PATH="$TOOLCHAIN_BASE_PATH/$path_suffix:$PATH"
done

if [ "$EXTRA_HOST_ENV" == "true" ]; then
    echo "--- 正在为 S25 风格项目设置额外的 HOST 环境变量 ---"
    LLD_COMPILER_RT="-fuse-ld=lld --rtlib=compiler-rt"
    sysroot_flags+="--sysroot=$TOOLCHAIN_BASE_PATH/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8/sysroot "
    cflags+="-I$TOOLCHAIN_BASE_PATH/kernel-build-tools/linux-x86/include "
    ldflags+="-L $TOOLCHAIN_BASE_PATH/kernel-build-tools/linux-x86/lib64 "
    ldflags+=${LLD_COMPILER_RT}
    export LD_LIBRARY_PATH="$TOOLCHAIN_BASE_PATH/kernel-build-tools/linux-x86/lib64"
    export HOSTCFLAGS="$sysroot_flags $cflags"
    export HOSTLDFLAGS="$sysroot_flags $ldflags"
fi

# --- 核心编译参数 ---
MAKE_ARGS="O=out ARCH=arm64 CC=clang LLVM=1 LLVM_IAS=1"

# 1. 清理 & 应用 defconfig
rm -rf out
make ${MAKE_ARGS} $MAIN_DEFCONFIG

# 2. 后处理配置
echo "--- 正在禁用三星安全特性 ---"
DISABLE_FLAGS="-d UH -d RKP -d KDP -d SECURITY_DEFEX -d INTEGRITY -d FIVE -d TRIM_UNUSED_KSYMS"
for flag in $(echo "$DISABLE_SECURITY_JSON" | jq -r '.[]'); do
  DISABLE_FLAGS+=" -d $flag"
done
./scripts/config --file out/.config $DISABLE_FLAGS

# 3. 配置 LTO
if [ -n "$LTO" ]; then ./scripts/config --file out/.config -e LTO_CLANG_${LTO^^} -d LTO_CLANG_THIN -d LTO_CLANG_FULL; fi

# 4. 设置版本号
if [ "$VERSION_METHOD" == "file" ]; then
    echo "${LOCALVERSION_BASE}-${BRANCH_NAME}-g$(git rev-parse --short HEAD)" > ./localversion
    MAKE_ARGS+=""
else
    MAKE_ARGS+=" LOCALVERSION=${LOCALVERSION_BASE}-${BRANCH_NAME}"
fi

# 5. 编译内核
echo "--- 开始编译内核 (-j$(nproc)) ---"
if command -v ccache &> /dev/null; then export CCACHE_EXEC=$(which ccache); ccache -M 5G; export PATH="/usr/lib/ccache:$PATH"; fi
ccache -s
make -j$(nproc) ${MAKE_ARGS} 2>&1 | tee kernel_build_log.txt
BUILD_STATUS=${PIPESTATUS[0]}
ccache -s
if [ "$VERSION_METHOD" == "file" ]; then echo -n > ./localversion; fi
if [ $BUILD_STATUS -ne 0 ]; then echo "--- 内核编译失败！ ---"; exit 1; fi
echo -e "\n--- 内核编译成功！ ---\n"

# 6. 打包
cd out
git clone --depth=1 "${ANYKERNEL_REPO}" -b "${ANYKERNEL_BRANCH}" AnyKernel3
cp arch/arm64/boot/Image AnyKernel3/Image
cd AnyKernel3
if [ "$DO_PATCH_LINUX" == "false" ]; then echo "--- 根据配置，跳过 patch_linux ---"; rm -f patch_linux; fi
if [ -f "patch_linux" ]; then chmod +x ./patch_linux && ./patch_linux && mv oImage zImage && rm -f Image oImage patch_linux; else mv Image zImage; fi
kernel_release=$(cat ../include/config/kernel.release)
final_name="${ZIP_NAME_PREFIX}_${kernel_release}_${BRANCH_NAME}_$(date '+%Y%m%d')"
zip -r9 "../${final_name}.zip" . -x "*.zip" -x "tools/*" -x "README.md" -x "LICENSE" -x '.*' -x '*/.*'
cd ../..

# 7. 发布
if [ "$AUTO_RELEASE" != "true" ]; then echo "--- 已跳过自动发布 ---"; exit 0; fi
echo -e "\n--- 开始发布到 GitHub Release ---"
if ! command -v gh &> /dev/null; then echo "错误: 未找到 'gh' 命令。"; exit 1; fi
if [ -z "$GH_TOKEN" ]; then echo "错误: 环境变量 'GH_TOKEN' 未设置。"; exit 1; fi
TAG="release-${BRANCH_NAME}-$(date +%Y%m%d-%H%M%S)"
RELEASE_TITLE="新内核构建 - ${kernel_release} (${BRANCH_NAME} | $(date +'%Y-%m-%d %R'))"
RELEASE_NOTES="由通用构建流程在 $(date) 自动发布。"
PRERELEASE_FLAG=""
if [ "$IS_PRERELEASE" == "true" ]; then PRERELEASE_FLAG="--prerelease"; RELEASE_TITLE="[预发布] ${RELEASE_TITLE}"; fi
UPLOAD_FILE_PATH=$(realpath "out/${final_name}.zip")
gh release create "$TAG" "$UPLOAD_FILE_PATH" --repo "$GITHUB_REPO" --title "$RELEASE_TITLE" --notes "$RELEASE_NOTES" --target "$BRANCH_NAME" $PRERELEASE_FLAG