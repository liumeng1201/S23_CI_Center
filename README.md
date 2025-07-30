# 通用 Android 内核持续集成中心

这是一个高度自动化、配置驱动的 Android 内核 CI/CD (持续集成/持续部署) 中心。它旨在作为所有内核项目的统一构建、更新和发布平台，将 CI/CD 逻辑与内核源码完全分离，以实现最大程度的可维护性和扩展性。

## 核心设计理念

本系统采用“中央控制”架构，由两部分组成：

1.  **中央构建仓库 (`Kokuban_Kernel_CI_Center`)**:
    * **唯一的逻辑中心**：所有工作流 (Workflows)、构建脚本和项目配置都集中存放于此。
    * **配置驱动**：通过一个简单的 JSON 文件 (`projects.json`) 来定义和管理所有内核项目。
    * **自动化引擎**：负责执行所有自动化任务，包括监视上游源码、更新内核仓库、触发编译和发布。

2.  **内核源码仓库 (例如 `android_kernel_samsung_sm8550_S23`)**:
    * **保持纯净**：只存放内核相关的源码，不包含任何 CI/CD 脚本或工作流。
    * **被动触发**：仅包含一个极简的触发器工作流，其唯一作用是在特定分支接收到代码推送时，通知中央构建仓库来执行编译。

## 安装与使用指南

### 首次安装

1.  **创建中央仓库**: 在 GitHub 上创建一个新的 **私有** 仓库，命名为 `Kokuban_Kernel_CI_Center`。将本项目中的所有文件和目录结构添加到该仓库。

2.  **生成 Personal Access Token (PAT)**:
    * 进入您的 GitHub 设置 -> Developer settings -> Personal access tokens -> Tokens (classic)。
    * 创建一个新令牌，授予 **`repo`** (完全控制) 和 **`workflow`** (修改工作流) 权限。
    * **立即复制并妥善保管** 这个令牌。

3.  **配置中央仓库 Secrets**:
    * 进入 `Kokuban_Kernel_CI_Center` 仓库的 `Settings` -> `Secrets and variables` -> `Actions`。
    * 创建三个新的仓库 Secret：
        * `ADMIN_TOKEN`: 粘贴您刚刚生成的 PAT。
        * `GH_TOKEN`: 同样粘贴那个 PAT。
        * `CI_TOKEN`: 再次粘贴那个 PAT (此 Secret 也会在后续步骤中被内核仓库使用)。

4.  **一键配置所有内核仓库**:
    * 进入 `Kokuban_Kernel_CI_Center` 仓库的 `Actions` 页面。
    * 在左侧找到 `1. Setup Kernel Repositories` 工作流。
    * 点击 `Run workflow` 按钮，然后确认执行。
    * **等待该工作流执行完毕。** 它会自动清理并配置您在 `projects.json` 中定义的所有内核仓库。

### 如何添加一个新项目 (推荐方式)

我们提供了一个自动化工作流来简化添加新项目的流程。

1.  **启动添加向导**:
    * 进入 `Kokuban_Kernel_CI_Center` 仓库的 `Actions` 页面。
    * 在左侧工作流列表中，选择 `0. Add New Kernel Project`。
    * 点击 `Run workflow` 按钮。

2.  **填写项目信息**:
    * 一个表单会展现在你面前。请仔细填写新内核项目的`项目唯一标识`。
    * 对于其他的多行输入框，**严格按照每个输入框描述中要求的顺序，每行填写一项信息**。例如，在 `core_config` 输入框中，第一行填写仓库路径，第二行填写 Defconfig 文件名，以此类推。

3.  **执行并完成**:
    * 填写完毕后，点击 "Run workflow" 按钮。
    * 工作流会自动解析您的输入，修改 `projects.json` 和其他相关的工作流文件，并将这些更改推送到仓库。

4.  **执行后续步骤**:
    * 工作流的日志会输出清晰的后续操作指引。请根据指引完成以下两个关键步骤：
        * **为新仓库添加 Secret**: 访问你新项目的内核仓库，在 `Settings` -> `Secrets` 中添加名为 `CI_TOKEN` 的 Secret，值为你的 PAT。
        * **初始化新仓库**: 回到本仓库，再次运行 `1. Setup Kernel Repositories` 工作流，它会自动为你的新项目配置好触发器。

### 日常使用

* **手动编译**:
    1.  进入 `Kokuban_Kernel_CI_Center` 仓库的 `Actions` 页面。
    2.  选择 `4. Universal Kernel Builder`。
    3.  点击 `Run workflow`，在下拉菜单中选择您想编译的项目和分支，然后执行。

* **手动更新 KernelSU**:
    1.  进入 `Kokuban_Kernel_CI_Center` 仓库的 `Actions` 页面。
    2.  选择 `2. Manual Update KernelSU`。
    3.  点击 `Run workflow`，选择要更新的项目和 KernelSU 类型，然后执行。
    4.  该操作会自动触发 `4. Universal Kernel Builder` 进行编译和发布。

* **自动流程**:
    * **上游更新**: `3. Watch Upstream KernelSU` 会定时检查更新。一旦发现上游有新 commit，它会自动更新您的内核仓库源码并推送。
    * **代码推送**: 任何到内核仓库 `ksu`, `mksu`, `sukisuultra` 分支的推送（无论是您手动推送还是由上游监视器自动推送），都会触发 `4. Universal Kernel Builder` 进行编译和发布。

## 核心组件详解

### 1. `configs/projects.json` - 项目大脑

这是整个系统的核心配置文件。它是一个 JSON 文件，定义了每一个需要本系统管理的内核项目。所有项目配置都由 `0. Add New Kernel Project` 工作流自动管理。

### 2. `scripts/build.sh` - 通用构建脚本

这是一个高度参数化的 Shell 脚本，负责实际的编译、打包和发布工作。它不包含任何硬编码的项目信息，所有配置均通过环境变量从 `projects.json` 动态读取。

### 3. `.github/workflows/` - 自动化工作流

* **`0-add-new-project.yml`**: **(推荐)** 一键式交互向导，用于向 CI 中心添加新的内核项目。
* **`1-setup-kernel-repos.yml`**: **一键式** 初始化/同步所有内核仓库的配置。
* **`2-update-kernelsu.yml`**: **手动** 为指定的项目和分支更新 KernelSU 源码。
* **`3-upstream-watcher.yml`**: **自动** 监视上游 KernelSU 仓库的更新。
* **`4-universal-build.yml`**: **核心构建工作流**，执行所有编译任务。
