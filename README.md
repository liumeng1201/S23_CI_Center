# Kokuban 内核 CI 中心

<p align="center">
<img src="https://raw.githubusercontent.com/YuzakiKokuban/Kokuban_Kernel_CI_Center/main/docs/kokuban_logo.png" alt="Logo" width="150">
</p>

<p align="center">
<a href="https://github.com/YuzakiKokuban/Kokuban_Kernel_CI_Center/actions"><img src="https://img.shields.io/github/actions/workflow/status/YuzakiKokuban/Kokuban_Kernel_CI_Center/4-universal-build.yml?branch=main&style=for-the-badge&logo=githubactions&logoColor=white" alt="构建状态"></a>
<a href="https://github.com/YuzakiKokuban/Kokuban_Kernel_CI_Center/blob/main/LICENSE"><img src="https://img.shields.io/github/license/YuzakiKokuban/Kokuban_Kernel_CI_Center?style=for-the-badge&color=blue" alt="许可证"></a>
</p>

这是一个为 Android 内核开发者设计的、高度自动化的持续集成与部署 (CI/CD) 中心。它采用“中央集权”的设计理念，将所有内核项目的构建、管理、发布和通知流程统一到一个中央仓库中，实现了真正的 GitOps 工作流。

## 核心功能

* **✨ 统一管理**: 在一个地方管理所有内核项目。不再需要在每个内核仓库中维护复杂的 CI 脚本。
* **🚀 全面自动化**: 从检测上游更新、编译内核、创建 GitHub Release，到自动部署和重启推送服务，全程自动化。
* **⚙️ 配置驱动**: 只需修改 `configs/projects.json` 文件，即可轻松添加、修改或移除内核项目，CI/CD 流程会自动适配。
* **面板化操作**: 通过一个[网页管理面板](https://yuzakikokuban.github.io/Kokuban_Kernel_CI_Center/) (暂未正式上线) 即可触发构建、查看状态，无需深入了解 GitHub Actions。
* **🔔 实时推送**: 内置一个基于 Flask 的轻量级推送服务器，可通过 Webhook 接收新版本发布通知，并立即推送到 Telegram 等平台。
* **灵活的构建策略**: 支持自动触发的测试构建、一键触发的全部分支正式版发布，以及为节省带宽而设计的周常差分包构建。

## 架构概览

```mermaid
graph TB
    %% 中央管理仓库部分
    subgraph "中央管理仓库 (Kokuban_Kernel_CI_Center)"
        A[GitHub Actions 工作流]
        B[构建脚本 scripts/]
        C[项目配置 configs/]
        D[推送服务器代码 push_server/]
        
        A1[0-add-new-project.yml]
        A2[1-setup-kernel-repos.yml]
        A3[2-update-kernelsu.yml]
        A4[3-upstream-watcher.yml]
        A5[4-universal-build.yml]
        A6[5-deploy-push-server.yml]
        A7[6-release-all-branches.yml]
        
        C1[projects.json]
        C2[upstream_commits.json]
    end
    
    %% 内核源码仓库部分
    subgraph "内核源码仓库 (多个)"
        K1[内核仓库1<br/>android_kernel_xxx]
        K2[内核仓库2<br/>android_kernel_yyy]
        K3[内核仓库N<br/>...]
        
        K1A[源码分支<br/>main/ksu/mksu/sukisuultra]
        K2A[源码分支]
        K3A[源码分支]
    end
    
    %% 推送服务器部分
    subgraph "推送服务器 (自托管)"
        P[Flask 应用]
        P1[Webhook 接收器]
        P2[消息格式化]
        P3[Telegram Bot API]
        P4[SQLite 数据库]
        P5[配置管理]
    end
    
    %% 外部服务
    subgraph "外部服务"
        T[Telegram]
        G[GitHub Releases]
        U[上游 KernelSU]
    end
    
    %% 用户交互
    subgraph "用户交互"
        U1[开发者 Push 代码]
        U2[管理面板操作]
        U3[手动触发工作流]
    end
    
    %% 数据流向
    %% 内核仓库 -> 中央仓库
    K1 -.->|repository_dispatch<br/>触发构建| A5
    K2 -.->|repository_dispatch<br/>触发构建| A5
    K3 -.->|repository_dispatch<br/>触发构建| A5
    
    %% 用户 -> 中央仓库
    U1 --> K1
    U2 --> A
    U3 --> A
    
    %% 中央仓库内部关系
    C1 --> A5
    C2 --> A3
    B --> A5
    A1 --> C1
    A2 --> K1
    A2 --> K2
    A2 --> K3
    
    %% 工作流关系
    A5 --> A7
    A3 --> K1
    A3 --> K2
    A3 --> K3
    
    %% 中央仓库 -> 推送服务器
    D --> A6
    A6 --> P
    
    %% 中央仓库 -> 发布
    A5 --> G
    A7 --> G
    
    %% 发布 -> 推送服务器
    G -->|Webhook 通知| P1
    
    %% 推送服务器 -> 外部服务
    P3 --> T
    
    %% 上游监控
    U --> A3
    U --> A4
    
    %% 样式
    classDef central fill:#e1f5fe,stroke:#01579b,stroke-width:2px
    classDef kernel fill:#f3e5f5,stroke:#4a148c,stroke-width:2px
    classDef push fill:#e8f5e8,stroke:#1b5e20,stroke-width:2px
    classDef external fill:#fff3e0,stroke:#e65100,stroke-width:2px
    classDef user fill:#fce4ec,stroke:#880e4f,stroke-width:2px
    
    class A,B,C,D,A1,A2,A3,A4,A5,A6,A7,C1,C2 central
    class K1,K2,K3,K1A,K2A,K3A kernel
    class P,P1,P2,P3,P4,P5 push
    class T,G,U external
    class U1,U2,U3 user

本系统由三个核心部分组成，协同工作：

1. **中央管理仓库 (`Kokuban_Kernel_CI_Center`)**:

   * **单一事实来源 (Single Source of Truth)**: 存储所有工作流 (`.github/workflows`)、构建脚本 (`scripts/`)、项目配置 (`configs/`) 以及推送服务器的应用代码 (`push_server/`)。

   * **自动化大脑**: 执行所有自动化任务，是整个系统的控制核心。

2. **内核源码仓库** (例如 `android_kernel_samsung_sm8550_S23`):

   * **保持纯净**: 只存放内核源码，不包含任何 CI/CD 逻辑。

   * **被动触发**: 内核源码的 `git push` 会通过一个轻量级的 `repository_dispatch` 触发器，向中央仓库“请求”构建。

3. **推送服务器**:

   * **发布守望者**: 部署在您自己服务器上的 Web 服务，通过安全的 GitHub Webhook 接收发布通知。

   * **GitOps 实践**: 应用代码、依赖和配置模板都由中央仓库管理。当 `push_server/` 目录更新时，CI 会自动 SSH 到服务器完成部署和重启。

## 快速上手指南

### 首次配置

1. **克隆中央仓库**:
   在 GitHub 上创建一个新的**私有**仓库，将本项目的所有文件克隆进去。

2. **生成 Personal Access Token (PAT)**:

   * 前往您的 GitHub 设置 → Developer settings → Personal access tokens。

   * 创建一个新令牌 (classic)，并授予 `repo` 和 `workflow` 权限。

   * **请妥善保管此令牌，它将用于后续的配置。**

3. **配置仓库 Secrets**:

   * 进入中央仓库的 `Settings` → `Secrets and variables` → `Actions`。

   * 添加以下 **8 个** Secrets:

     * `ADMIN_TOKEN`: 用于管理仓库配置的 PAT (通常就是第二步生成的)。

     * `GH_TOKEN`: 同上，用于发布 Release。

     * `CI_TOKEN`: 拥有 `repo` 权限的 PAT，用于内核仓库触发中央工作流。

     * `PUSH_SERVER_HOST`: 您的推送服务器的 IP 地址或域名。

     * `PUSH_SERVER_USER`: SSH 登录用户名。

     * `PUSH_SERVER_SSH_KEY`: 用于 SSH 登录的私钥。

     * `TELEGRAM_BOT_TOKEN`: 您的 Telegram Bot 的 Token。

     * `PUSH_SERVER_WEBHOOK_SECRET`: 用于验证 Webhook 请求的密钥 (一个随机长字符串)。

4. **配置 `projects.json`**:

   * 打开 `configs/projects.json` 文件。

   * 根据您的需求，修改或添加新的项目配置。确保 `repo`、`defconfig` 等关键信息正确无误。

5. **一键初始化所有内核仓库**:

   * 前往中央仓库的 `Actions` 页面。

   * 找到并手动运行 `1. Setup Kernel Repositories` 工作流。

   * 此工作流会自动为您在 `projects.json` 中定义的所有内核仓库：

     * 创建 `CI_TOKEN` Secret。

     * 创建并配置用于接收 Release 通知的 Webhook。

     * 生成并推送用于触发构建的 `.github/workflows/trigger-central-build.yml` 文件。

### 添加一个新内核项目

我们强烈推荐使用自动化的方式添加新项目：

1. **运行添加向导**:

   * 前往 `Actions` 页面，运行 `0. Add New Kernel Project` 工作流。

   * 根据表单提示，输入新项目的各项信息。

2. **确认变更**:

   * 工作流会自动创建一个 Pull Request，其中包含了对 `projects.json` 和相关模板文件的修改。

   * 检查无误后，合并此 PR。

3. **重新初始化**:

   * 再次运行 `1. Setup Kernel Repositories` 工作流，即可为新项目自动配置好 CI 触发器和 Webhook。

### 日常使用

* **开发与测试**:

  * 向内核仓库的任何受支持分支 (`main`, `ksu`, `mksu`, `sukisuultra`) 推送代码，将自动触发**预发布 (pre-release)** 构建。

  * 如果想跳过某次构建，只需在 commit message 中包含 `[skip ci]`。

  * 您也可以通过[管理面板](https://yuzakikokuban.github.io/Kokuban_Kernel_CI_Center/) (暂未正式上线) 或手动运行 `4. Universal Kernel Builder` 工作流来进行自定义构建。

* **正式发布**:

  * 当您准备好发布正式版时，运行 `6. Release All Branches` 工作流。

  * 选择目标项目，系统会自动为该项目的所有分支并行构建，并创建**正式版 Release**。

* **管理推送服务**:

  * 修改 `push_server/` 目录下的任何文件并推送到 `main` 分支。

  * `5. Deploy Push Server` 工作流会自动触发，将最新的应用部署到您的服务器并重启服务。

## 核心组件解析

### 配置文件 (`configs/`)

* `projects.json`: **项目大脑**。定义了每个内核项目的所有元数据，包括源码仓库、编译配置、工具链信息、AnyKernel3 打包仓库以及推送服务器的 Webhook 地址。

* `upstream_commits.json`: 用于追踪上游 KernelSU 项目的最新 commit，是 `2-update-kernelsu.yml` 工作流的数据来源。

### 推送服务 (`push_server/`)

一个轻量、高效的 Flask 应用，专为接收 GitHub Webhook 而设计。

* `app.py`: 核心逻辑。包含 Webhook 签名验证、Payload 解析、消息格式化以及与 Telegram Bot API 的交互。它还内置了基于 `peewee` 的 SQLite 数据库，用于缓存文件的 `file_id`，避免重复上传。

* `config.json`: 推送目标的配置文件。

* `requirements.txt`: Python 依赖项。

### GitHub Actions 工作流 (`.github/workflows/`)

* `0-add-new-project.yml`: **(推荐)** 一键式交互向导，用于添加新项目。

* `1-setup-kernel-repos.yml`: 初始化/同步所有内核仓库的配置。

* `2-update-kernelsu.yml`: 为指定项目更新 KernelSU 源码。

* `3-upstream-watcher.yml`: **(自动)** 定时监视上游 KernelSU 仓库的更新。

* `4-universal-build.yml`: **通用构建调度器**，负责接收所有构建请求。

* `5-deploy-push-server.yml`: 当 `push_server/` 目录更新时，自动部署应用。

* `6-release-all-branches.yml`: **一键发布流**，为指定项目的所有分支构建并发布正式版。

* `reusable-build-job.yml`: **可复用的构建引擎**，封装了下载工具链、编译内核、打包、发布的完整逻辑。

## 贡献

欢迎通过 Pull Request 或 Issues 为本项目做出贡献。在提交代码前，请确保您的代码风格与项目保持一致。

## 许可证

本项目基于 [GPL-3.0 License](LICENSE) 开源。