#!/usr/bin/env bash
set -e

# --- 从环境变量读取配置 ---
MAIN_DEFCONFIG="${PROJECT_DEFCONFIG:?PROJECT_DEFCONFIG 未设置}"
LOCALVERSION_BASE="${PROJECT_LOCALVERSION_BASE:?PROJECT_LOCALVERSION_BASE 未设置}"
LTO="${PROJECT_LTO}"
TOOLCHAIN_PATH_PREFIX="${PROJECT_TOOLCHAIN_PATH_PREFIX:?PROJECT_TOOLCHAIN_PATH_PREFIX 未设置}"
TOOLCHAIN_PATH_EXPORTS_JSON="${PROJECT_TOOLCHAIN_PATH_EXPORTS:?PROJECT_TOOLCHAIN_PATH_EXPORTS 未设置}"
ZIP_NAME_PREFIX="${PROJECT_ZIP_NAME_PREFIX:?PROJECT_ZIP_NAME_PREFIX 未设置}"
GITHUB_REPO="${PROJECT_REPO:?PROJECT_REPO 未设置}"
AUTO_RELEASE="${DO_RELEASE:?DO_RELEASE 未设置}"
IS_PRERELEASE="${IS_PRERELEASE_INPUT:?IS_PRERELEASE_INPUT 未设置}"
VERSION_METHOD="${PROJECT_VERSION_METHOD:-param}"
EXTRA_HOST_ENV="${PROJECT_EXTRA_HOST_ENV:-false}"
DISABLE_SECURITY_JSON="${PROJECT_DISABLE_SECURITY:-[]}"

echo "============================================================================"
echo "MAIN_DEFCONFIG="${MAIN_DEFCONFIG}
echo "LOCALVERSION_BASE="${LOCALVERSION_BASE}
echo "LTO="${LTO}
echo "TOOLCHAIN_PATH_PREFIX="${TOOLCHAIN_PATH_PREFIX}
echo "TOOLCHAIN_PATH_EXPORTS_JSON="${TOOLCHAIN_PATH_EXPORTS_JSON}
echo "ZIP_NAME_PREFIX="${ZIP_NAME_PREFIX}
echo "GITHUB_REPO="${GITHUB_REPO}
echo "AUTO_RELEASE="${AUTO_RELEASE}
echo "IS_PRERELEASE="${IS_PRERELEASE}
echo "VERSION_METHOD="${VERSION_METHOD}
echo "EXTRA_HOST_ENV="${EXTRA_HOST_ENV}
echo "DISABLE_SECURITY_JSON="${DISABLE_SECURITY_JSON}
echo "============================================================================"

# --- 动态决定是否运行 patch_linux ---
DO_PATCH_LINUX=false
if [[ "$BRANCH_NAME" == "sukisuultra" ]]; then
  if [[ "$PROJECT_KEY" == "s24_sm8650" || "$PROJECT_KEY" == "s25_sm8750" || "$PROJECT_KEY" == "tabs10_mt6989" || "$PROJECT_KEY" == "s25e_sm8750" || "$PROJECT_KEY" == "s24_s5e9945" || "$PROJECT_KEY" == "tabs10fe_s5e8855" || "$PROJECT_KEY" == "z6_sm8650" ]]; then
    DO_PATCH_LINUX=true
  fi
fi

# --- 根据分支名生成版本后缀 ---
case "$BRANCH_NAME" in
  main)
    VERSION_SUFFIX="LKM"
    ;;
  ksu)
    VERSION_SUFFIX="KSU"
    ;;
  mksu)
    VERSION_SUFFIX="MKSU"
    ;;
  sukisuultra)
    VERSION_SUFFIX="SukiSUU"
    ;;
  *)
    VERSION_SUFFIX="$BRANCH_NAME" # 如果有其他分支，则直接使用分支名
    ;;
esac

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
# 【关键修复】从 PROJECT_KEY (例如 "S24fe_s5e9945") 中提取 SOC 名称 ("s5e9945")
TARGET_SOC_NAME=$(echo "$PROJECT_KEY" | cut -d'_' -f2)
echo "--- 自动检测到 TARGET_SOC 为: ${TARGET_SOC_NAME} ---"

# 将 TARGET_SOC=${TARGET_SOC_NAME} 添加到 MAKE_ARGS 中
MAKE_ARGS="O=out ARCH=arm64 CC=clang LLVM=1 LLVM_IAS=1 TARGET_SOC=${TARGET_SOC_NAME}"

# 【条件修复】仅为 Z4 项目明确指定 SUBARCH 和 CROSS_COMPILE
if [[ "$ZIP_NAME_PREFIX" == "Z4_Kernel" ]]; then
  echo "--- Z4 project detected. Applying SUBARCH and CROSS_COMPILE flags. ---"
  MAKE_ARGS+=" SUBARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu-"
fi

if [[ "$ZIP_NAME_PREFIX" == "Z3_Kernel" ]]; then
  echo "--- Z3 project detected. Applying SUBARCH and CROSS_COMPILE flags. ---"
  KERNEL_LLVM_BIN=$TOOLCHAIN_BASE_PATH/clang/host/linux-x86/clang-r416183b/bin
  BUILD_CROSS_COMPILE=$TOOLCHAIN_BASE_PATH/gcc/linux-x86/host/x86_64-linux-glibc2.17-4.8/x86_64-linux/bin
  CLANG_TRIPLE=aarch64-linux-gnu-
  MAKE_ARGS+=" SUBARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- REAL_CC=$KERNEL_LLVM_BIN CLANG_TRIPLE=$CLANG_TRIPLE CONFIG_SECTION_MISMATCH_WARN_ONLY=y "
fi

# 1. 清理 & 应用 defconfig
rm -rf out
echo "============================================================================"
echo "---MAKE_ARGS内容---"
echo ${MAKE_ARGS}
echo "---MAIN_DEFCONFIG内容---"
echo $MAIN_DEFCONFIG
echo "============================================================================"
make ${MAKE_ARGS} $MAIN_DEFCONFIG

# 2. 后处理配置
echo "--- 正在禁用三星安全特性 ---"
DISABLE_FLAGS="-d UH -d RKP -d KDP -d SECURITY_DEFEX -d INTEGRITY -d FIVE -d TRIM_UNUSED_KSYMS"
for flag in $(echo "$DISABLE_SECURITY_JSON" | jq -r '.[]'); do
  DISABLE_FLAGS+=" -d $flag"
done
./scripts/config --file out/.config $DISABLE_FLAGS

# 3. 【逻辑修复】正确配置 LTO
if [ "$LTO" = "thin" ]; then
  echo "--- Enabling ThinLTO ---"
  ./scripts/config --file out/.config -e LTO_CLANG_THIN -d LTO_CLANG_FULL
elif [ "$LTO" = "full" ]; then
  echo "--- Enabling FullLTO ---"
  ./scripts/config --file out/.config -e LTO_CLANG_FULL -d LTO_CLANG_THIN
else
  echo "--- LTO not specified, disabling both ---"
  ./scripts/config --file out/.config -d LTO_CLANG_THIN -d LTO_CLANG_FULL
fi

# 4. 设置版本号
FINAL_LOCALVERSION="${LOCALVERSION_BASE}-${VERSION_SUFFIX}"
if [ "$VERSION_METHOD" == "file" ]; then
    echo "${FINAL_LOCALVERSION}-g$(git rev-parse --short HEAD)" > ./localversion
    # 当使用文件方法时，不应将 LOCALVERSION 传递给 make
    MAKE_ARGS_BUILD="${MAKE_ARGS}"
else
    MAKE_ARGS_BUILD="${MAKE_ARGS} LOCALVERSION=${FINAL_LOCALVERSION}"
fi

# 5. 设置构建时间戳
echo "--- 正在设置 KBUILD_BUILD_TIMESTAMP ---"
export KBUILD_BUILD_TIMESTAMP=$(date -u +"%a %b %d %H:%M:%S %Z %Y")
echo "Build timestamp set to: $KBUILD_BUILD_TIMESTAMP"

# 6. 编译内核
echo "--- 开始编译内核 (-j$(nproc)) ---"
if command -v ccache &> /dev/null; then export CCACHE_EXEC=$(which ccache); ccache -M 5G; export PATH="/usr/lib/ccache:$PATH"; fi
ccache -s
echo "" >> kernel_build_log.txt
echo "---MAKE_ARGS_BUILD内容---" >> kernel_build_log.txt
echo ${MAKE_ARGS_BUILD} >> kernel_build_log.txt
echo "" >> kernel_build_log.txt
make -j$(nproc) ${MAKE_ARGS_BUILD} 2>&1 | tee kernel_build_log.txt
BUILD_STATUS=${PIPESTATUS[0]}
ccache -s
if [ "$VERSION_METHOD" == "file" ]; then echo -n > ./localversion; fi
if [ $BUILD_STATUS -ne 0 ]; then echo "--- 内核编译失败！ ---"; exit 1; fi
echo -e "\n--- 内核编译成功！ ---\n"

echo "============================================================================"
echo "---out目录内容---"
ls -al out/
echo "---out/arch/arm64/boot目录内容---"
ls -al out/arch/arm64/boot/
echo "---out/arch/arm64/boot/dts目录内容---"
ls -al out/arch/arm64/boot/dts
echo "============================================================================"

# 7. 打包
cd out
echo "--- 从缓存目录复制 AnyKernel3 ---"
cp -r ../../anykernel_repo ./AnyKernel3

cp arch/arm64/boot/Image AnyKernel3/Image
cd AnyKernel3
if [ "$DO_PATCH_LINUX" == "false" ]; then echo "--- 根据配置，跳过 patch_linux ---"; rm -f patch_linux; fi
if [ -f "patch_linux" ]; then chmod +x ./patch_linux && ./patch_linux && mv oImage zImage && rm -f Image oImage patch_linux; else mv Image zImage; fi
kernel_release=$(cat ../include/config/kernel.release)
final_name="${ZIP_NAME_PREFIX}_${kernel_release}_${VERSION_SUFFIX}_$(date '+%Y%m%d')"
zip -r9 "../${final_name}.zip" . -x "*.zip" -x "tools/boot.img.lz4" -x "tools/libmagiskboot.so" -x "README.md" -x "LICENSE" -x '.*' -x '*/.*'
cd ../..

# 8. 发布
if [ "$AUTO_RELEASE" != "true" ]; then echo "--- 已跳过自动发布 ---"; exit 0; fi
echo -e "\n--- 开始发布到 GitHub Release ---"
if ! command -v gh &> /dev/null; then echo "错误: 未找到 'gh' 命令。"; exit 1; fi
if [ -z "$GH_TOKEN" ]; then echo "错误: 环境变量 'GH_TOKEN' 未设置。"; exit 1; fi
TAG="release-${VERSION_SUFFIX}-$(date +%Y%m%d-%H%M%S)"
RELEASE_TITLE="新内核构建 - ${kernel_release} (${VERSION_SUFFIX} | $(date +'%Y-%m-%d %R'))"
RELEASE_NOTES="由通用构建流程在 $(date) 自动发布。"
PRERELEASE_FLAG=""
if [ "$IS_PRERELEASE" == "true" ]; then PRERELEASE_FLAG="--prerelease"; RELEASE_TITLE="[预发布] ${RELEASE_TITLE}"; fi
UPLOAD_FILE_PATH=$(realpath "out/${final_name}.zip")
gh release create "$TAG" "$UPLOAD_FILE_PATH" --repo "$GITHUB_REPO" --title "$RELEASE_TITLE" --notes "$RELEASE_NOTES" --target "$BRANCH_NAME" $PRERELEASE_FLAG
