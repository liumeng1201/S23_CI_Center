# 通用 Android 内核持续集成中心

这是一个高度自动化、配置驱动的 Android 内核 CI/CD (持续集成/持续部署) 中心。它旨在作为所有内核项目的统一构建、更新和发布平台，将 CI/CD 逻辑与内核源码完全分离，以实现最大程度的可维护性和扩展性。

## 核心设计理念

本系统采用“中央控制”架构，由两部分组成：

1. **中央构建仓库 (`Kokuban_Kernel_CI_Center`)**:

   * **唯一的逻辑中心**：所有工作流 (Workflows)、构建脚本和项目配置都集中存放于此。

   * **配置驱动**：通过一个简单的 JSON 文件 (`projects.json`) 来定义和管理所有内核项目，新增或修改项目无需更改任何工作流代码。

   * **自动化引擎**：负责执行所有自动化任务，包括监视上游源码、更新内核仓库、触发编译和发布。

2. **内核源码仓库 (例如 `android_kernel_samsung_sm8550_S23`)**:

   * **保持纯净**：只存放内核相关的源码，不包含任何 CI/CD 脚本或工作流。

   * **被动触发**：仅包含一个极简的触发器工作流，其唯一作用是在特定分支接收到代码推送时，通知中央构建仓库来执行编译。

## 核心组件详解

### 1. `configs/projects.json` - 项目大脑

这是整个系统的核心配置文件。它是一个 JSON 文件，定义了每一个需要本系统管理的内核项目。

**字段说明:**

| **键 (Key)** | **类型** | **描述** | **示例** |
| :--- | :--- | :--- | :--- |
| `repo` | String | 内核仓库的完整路径 (`用户名/仓库名`)。 | `"YuzakiKokuban/android_kernel_samsung_sm8550_S23"` |
| `defconfig` | String | 该项目使用的默认配置文件名。 | `"kalama_gki_defconfig"` |
| `localversion_base` | String | 内核版本号的基础字符串。 | `"-android13-Kokuban-Firefly-DYF1"` |
| `lto` | String | LTO (链接时优化) 配置。可选值为 `"thin"`, `"full"` 或 `""` (禁用)。 | `"thin"` |
| `supported_ksu` | Array | 一个字符串数组，列出此项目支持的 KernelSU 分支。 | `["sukisuultra", "mksu", "ksu"]` |
| `toolchain_urls` | Array | 工具链分卷压缩包的下载地址数组。 | `["url1", "url2"]` |
| `toolchain_path_prefix` | String | 工具链解压后，`prebuilts` 目录的相对路径。 | `"prebuilts"` 或 `"kernel_platform/prebuilts"` |
| `toolchain_path_exports` | Array | 需要添加到 `PATH` 环境变量的工具链子目录路径数组。 | `["build-tools/linux-x86/bin", ...]` |
| `anykernel_repo` | String | AnyKernel3 仓库的 URL。 | `"https://github.com/YuzakiKokuban/AnyKernel3.git"` |
| `anykernel_branch` | String | 针对此项目的 AnyKernel3 分支名。 | `"kalama"` |
| `zip_name_prefix` | String | 生成的刷机包文件名的前缀。 | `"S23_kernel"` |
| `version_method` | String | **(可选)** 设置版本号的方法。`"file"` 表示写入 `localversion` 文件。默认为 `"param"` (通过 make 参数传入)。 | `"file"` |
| `extra_host_env` | Boolean | **(可选)** 是否需要为 S25 风格的项目设置额外的 HOST 环境变量。默认为 `false`。 | `true` |
| `disable_security` | Array | **(可选)** 一个字符串数组，列出需要额外禁用的三星安全特性。 | `["PROCA", "GAF", ...]` |

### 2. `scripts/build.sh` - 通用构建脚本

这是一个高度参数化的 Shell 脚本，负责实际的编译、打包和发布工作。它不包含任何硬编码的项目信息，所有配置均通过环境变量从 `projects.json` 动态读取。

**智能逻辑**:

* **动态工具链路径**：根据 `toolchain_path_prefix` 和 `toolchain_path_exports` 自动构建正确的 `PATH`。

* **条件化 `patch_linux`**：脚本内部会根据当前编译的项目名 (`PROJECT_KEY`) 和分支名 (`BRANCH_NAME`) 自动判断是否需要执行 `patch_linux` 脚本，完美匹配您的复杂需求。

* **灵活的版本号处理**：根据 `version_method` 配置，自动选择是通过 `make` 参数传入版本号，还是通过写入 `localversion` 文件来设置。

### 3. `.github/workflows/` - 自动化工作流

#### `1-setup-kernel-repos.yml`

* **作用**: **一键式** 初始化/同步所有内核仓库的配置。

* **执行**: 手动触发。

* **流程**: 遍历 `projects.json`，克隆每一个内核仓库的所有相关分支，删除旧的 CI 文件，并根据 `templates/trigger-central-build.yml.tpl` 模板创建统一的触发器工作流。

#### `2-update-kernelsu.yml`

* **作用**: **手动** 为指定的项目和分支更新 KernelSU 源码。

* **执行**: 手动触发，需要选择目标项目和 KernelSU 类型。

* **流程**: 克隆指定仓库的指定分支，同步 `.gitignore`，运行最新的 `setup.sh`，然后将所有文件变动作为一个 commit 推送回去。

#### `3-upstream-watcher.yml`

* **作用**: **自动** 监视上游 KernelSU 仓库的更新。

* **执行**: 定时触发 (例如，每小时一次)。

* **流程**: 检查上游 `main` 或 `susfs-main` 分支的最新 commit。如果发现更新，它会自动执行与 `2-update-kernelsu.yml` 类似的操作，为所有相关项目更新源码。这个推送行为会自动触发下游的编译流程。

#### `4-universal-build.yml`

* **作用**: **核心构建工作流**，执行所有编译任务。

* **执行**:

  1. **手动触发**: 可在 Actions 页面选择任意项目和分支进行编译。

  2. **自动触发**: 由内核仓库的 `push` 事件通过 `repository_dispatch` 触发。

* **流程**: 解析 `projects.json` 获取配置 -> 检出内核源码 -> 下载并缓存工具链 -> 运行 `setup.sh` 注入 KernelSU -> 运行通用构建脚本 -> 发布到 Release。

## 安装与设置指南

1. **创建中央仓库**: 在 GitHub 上创建一个新的 **私有** 仓库，命名为 `Kokuban_Kernel_CI_Center`。将本文档中的所有文件和目录结构添加到该仓库。

2. **生成 Personal Access Token (PAT)**:

   * 进入您的 GitHub 设置 -> Developer settings -> Personal access tokens -> Tokens (classic)。

   * 创建一个新令牌，授予 **`repo`** (完全控制) 和 **`workflow`** (修改工作流) 权限。

   * **立即复制并妥善保管** 这个令牌。

3. **配置中央仓库 Secrets**:

   * 进入 `Kokuban_Kernel_CI_Center` 仓库的 `Settings` -> `Secrets and variables` -> `Actions`。

   * 创建两个新的仓库 Secret：

     * `ADMIN_TOKEN`: 粘贴您刚刚生成的 PAT。

     * `GH_TOKEN`: 同样粘贴那个 PAT。

4. **一键配置所有内核仓库**:

   * 进入 `Kokuban_Kernel_CI_Center` 仓库的 `Actions` 页面。

   * 在左侧找到 `1. Setup Kernel Repositories` 工作流。

   * 点击 `Run workflow` 按钮，然后确认执行。

   * **等待该工作流执行完毕。** 它会自动清理并配置您在 `projects.json` 中定义的所有内核仓库。

5. **为内核仓库添加 Secret**:

   * 进入您的 **每一个** 内核源码仓库 (S23, S24, ...)。

   * 进入 `Settings` -> `Secrets and variables` -> `Actions`。

   * 创建一个名为 `CI_TOKEN` 的新仓库 Secret，将您的 PAT 再次粘贴进去。

## 如何使用

### 手动编译

1. 进入 `Kokuban_Kernel_CI_Center` 仓库的 `Actions` 页面。

2. 选择 `4. Universal Kernel Builder`。

3. 点击 `Run workflow`，在下拉菜单中选择您想编译的项目和分支，然后执行。

### 手动更新 KernelSU

1. 进入 `Kokuban_Kernel_CI_Center` 仓库的 `Actions` 页面。

2. 选择 `2. Manual Update KernelSU`。

3. 点击 `Run workflow`，选择要更新的项目和 KernelSU 类型，然后执行。

4. 该操作会自动触发 `4. Universal Kernel Builder` 进行编译和发布。

### 自动流程

* **上游更新**: `3. Watch Upstream KernelSU` 会定时检查更新。一旦发现上游有新 commit，它会自动更新您的内核仓库源码并推送。

* **代码推送**: 任何到内核仓库 `ksu`, `mksu`, `sukisuultra` 分支的推送（无论是您手动推送还是由上游监视器自动推送），都会触发 `4. Universal Kernel Builder` 进行编译和发布。

### 如何添加一个新项目

1. 在 `configs/projects.json` 文件中，仿照现有格式，添加一个描述新项目的新 JSON 对象。

2. 在 `4-universal-build.yml` 和 `2-update-kernelsu.yml` 文件的 `workflow_dispatch` -> `project` -> `options` 列表中，加入新项目的 key。

3. **(重要)** 在新内核项目的仓库 `Settings -> Secrets` 中添加 `CI_TOKEN`。

4. 运行一次 `1. Setup Kernel Repositories` 工作流，它会自动为您的新项目配置好触发器。

5. 完成！新项目现已纳入全自动 CI/CD 体系。
