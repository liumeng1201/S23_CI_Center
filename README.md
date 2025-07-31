# 通用 Android 内核持续集成中心

这是一个高度自动化、配置驱动的 CI/CD 与 GitOps 中心。它不仅能作为所有内核项目的统一构建、更新和发布平台，还能自动化管理其配套的推送服务，实现了从代码提交到服务部署的端到端全生命周期管理。

## 核心设计理念

本系统采用“中央控制”架构，由三部分协同工作：

1.  **中央管理仓库 (`Kokuban_Kernel_CI_Center`)**:
    * **唯一的真实来源 (Single Source of Truth)**：所有工作流、构建脚本、项目配置，以及**推送服务器的应用代码**都集中存放于此。
    * **自动化引擎**：负责执行所有自动化任务，包括监视上游、更新源码、触发编译、配置 Webhook，以及**自动部署和重启推送服务**。

2.  **内核源码仓库 (例如 `android_kernel_samsung_sm8550_S23`)**:
    * **保持纯净**：只存放内核源码，不包含任何 CI/CD 逻辑。
    * **被动触发**：代码推送会通过一个极简的触发器，向中央仓库“下单”请求构建。

3.  **推送服务器 (`nas.kokuban.su`)**:
    * **发布接收方**：一个独立的 Web 服务，通过安全的 GitHub Webhook 接收新版本发布的通知。
    * **GitOps 管理**：其自身的应用代码、依赖和配置模板均由中央仓库管理，实现自动化部署。

## 安装与使用指南

### 首次安装

1.  **创建中央仓库**: 在 GitHub 上创建一个新的 **私有** 仓库，命名为 `Kokuban_Kernel_CI_Center`。将本项目中的所有文件和目录结构添加到该仓库。

2.  **生成 Personal Access Token (PAT)**:
    * 进入您的 GitHub 设置 -> Developer settings -> Personal access tokens -> Tokens (classic)。
    * 创建一个新令牌，授予 **`repo`** (完全控制) 和 **`workflow`** (修改工作流) 权限。
    * **立即复制并妥善保管** 这个令牌。

3.  **配置中央仓库 Secrets**:
    * 进入 `Kokuban_Kernel_CI_Center` 仓库的 `Settings` -> `Secrets and variables` -> `Actions`。
    * 创建以下 **6 个** 仓库 Secret：
        * `ADMIN_TOKEN`: 粘贴您刚刚生成的 PAT。
        * `GH_TOKEN`: 同样粘贴那个 PAT。
        * `CI_TOKEN`: 再次粘贴那个 PAT。
        * `PUSH_SERVER_HOST`: 您的推送服务器域名或 IP (例如 `nas.kokuban.su`)。
        * `PUSH_SERVER_USER`: 您用于 SSH 登录的用户名 (例如 `qxxxzzzz`)。
        * `PUSH_SERVER_SSH_KEY`: 您用于 SSH 登录的**私钥**。
        * `TELEGRAM_BOT_TOKEN`: 您的 Telegram Bot 令牌。
        * `PUSH_SERVER_WEBHOOK_SECRET`: 一个用于 Webhook 签名的安全随机字符串。

4.  **配置项目 `push_server`**:
    * 打开 `configs/projects.json` 文件。
    * 为您希望启用自动推送的每个项目，添加 `push_server` 配置块，并确保 `enabled` 为 `true`，`webhook_url` 正确无误。

5.  **一键配置所有内核仓库**:
    * 进入 `Kokuban_Kernel_CI_Center` 仓库的 `Actions` 页面。
    * 在左侧找到 `1. Setup Kernel Repositories` 工作流。
    * 点击 `Run workflow` 按钮，然后确认执行。
    * **等待该工作流执行完毕。** 它会自动为所有项目配置好 CI 触发器和**发布 Webhook**。

### 如何添加一个新项目 (推荐方式)

1.  **启动添加向导**: 运行 `0. Add New Kernel Project` 工作流。
2.  **填写项目信息**: 在表单中，**使用英文逗号 (`,`) 分隔**每一项信息。
3.  **执行并完成**: 工作流会自动修改 `projects.json` 和其他相关文件。
4.  **执行后续步骤**:
    * **为新仓库添加 Secret**: 访问新项目的仓库，在 `Settings` -> `Secrets` 中添加 `CI_TOKEN`。
    * **初始化新仓库**: 回到本仓库，再次运行 `1. Setup Kernel Repositories` 工作流，它会自动为新项目配置好触发器和 Webhook。

### 日常使用

* **内核开发**:
    * 任何到内核仓库 `main`, `ksu`, `mksu`, `sukisuultra` 分支的推送都会触发编译。
    * 编译成功并创建 Release 后，GitHub 会自动通过 Webhook 通知您的推送服务器。
    * **跳过构建**: 如果希望某次推送不触发 CI，只需在 commit message 中包含 `[skip ci]` 即可。

* **推送服务器开发**:
    * 修改 `push_server/` 目录下的任何文件（`app.py`, `config.json` 等）并推送到本仓库。
    * `5. Deploy Push Server` 工作流会自动触发，将最新的应用安全地部署到您的服务器并重启服务。

## 核心组件详解

### 1. `configs/projects.json` - 项目大脑

这是整个系统的核心配置文件。它定义了每一个内核项目及其配套的推送服务配置。

### 2. `push_server/` - 推送服务应用

此目录包含了推送服务器（Telegram Bot）的完整应用代码，实现了 GitOps 管理。

* `app.py`: 基于 Flask 的机器人核心逻辑，已集成结构化日志。
* `config.json`: 应用的配置文件模板，机密信息会由部署流自动注入。
* `requirements.txt`: Python 依赖清单。

### 3. `.github/workflows/` - 自动化工作流

* **`0-add-new-project.yml`**: **(推荐)** 一键式交互向导，用于向 CI 中心添加新的内核项目。
* **`1-setup-kernel-repos.yml`**: **一键式** 初始化/同步所有内核仓库的配置，包括 CI 触发器和 Webhook。
* **`2-update-kernelsu.yml`**: **手动** 为指定的项目和分支更新 KernelSU 源码。
* **`3-upstream-watcher.yml`**: **自动** 监视上游 KernelSU 仓库的更新。
* **`4-universal-build.yml`**: **核心构建工作流**，执行所有内核编译任务。
* **`5-deploy-push-server.yml`**: **推送服务部署流**，当 `push_server/` 目录更新时，自动将应用部署到您的服务器。
