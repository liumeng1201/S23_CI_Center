# 通用 Android 内核持续集成中心

这是一个高度自动化、配置驱动的 CI/CD 与 GitOps 中心。它不仅能作为所有内核项目的统一构建、更新和发布平台，还能自动化管理其配套的推送服务。  
**项目目标：** 简化 Android 内核开发者的持续集成流程，使构建、发布、推送一体化，安全且高效。

---

## 🌟 应用场景
- 支持多机型、多分支 Android 内核开发的统一自动构建与发布。
- 自动化内核编译、Release创建，并通过 Webhook/Telegram Bot 推送新版本。
- GitOps 管理推送服务器，降低运维负担。

---

## 系统架构图

![系统架构图](docs/architecture.png)

---

## 核心设计理念

本系统采用“中央控制”架构，由三部分协同工作：

1. **中央管理仓库 (`Kokuban_Kernel_CI_Center`)**  
   - **唯一的真实来源 (Single Source of Truth)：** 所有工作流、构建脚本、项目配置，以及推送服务器的应用代码都集中存放于此。  
   - **自动化引擎：** 负责执行所有自动化任务，包括监视上游、更新源码、触发编译、配置 Webhook，以及自动部署和重启推送服务。

2. **内核源码仓库**（如 `android_kernel_samsung_sm8550_S23`）  
   - **保持纯净：** 仅存放内核源码，不包含任何 CI/CD 逻辑。  
   - **被动触发：** 代码推送通过触发器向中央仓库“下单”请求构建。

3. **推送服务器 (`nas.kokuban.su`)**  
   - **发布接收方：** 独立 Web 服务，通过安全的 GitHub Webhook 接收新版本发布通知。  
   - **GitOps 管理：** 应用代码、依赖和配置模板均由中央仓库管理，实现自动化部署。

---

## 技术栈
- **主语言：** Python
- **Web框架：** Flask
- **自动化：** GitHub Actions
- **Bot服务：** Telegram Bot
- **配置管理：** JSON/YAML

---

## 安装与使用指南

### 首次安装

1. **创建中央仓库**  
   在 GitHub 上创建一个新的**私有**仓库，命名为 `Kokuban_Kernel_CI_Center`。将本项目中的所有文件和目录结构添加到该仓库。

2. **生成 Personal Access Token (PAT)**  
   - 进入 GitHub 设置 → Developer settings → Personal access tokens。  
   - 创建新令牌，授予 `repo` 和 `workflow` 权限。  
   - 妥善保管该令牌。

3. **配置仓库 Secrets**  
   - 仓库设置 → Secrets and variables → Actions  
   - 添加以下 **8 个** Secrets：`ADMIN_TOKEN`、`GH_TOKEN`、`CI_TOKEN`、`PUSH_SERVER_HOST`、`PUSH_SERVER_USER`、`PUSH_SERVER_SSH_KEY`、`TELEGRAM_BOT_TOKEN`、`PUSH_SERVER_WEBHOOK_SECRET`

4. **配置项目 `push_server`**  
   - 编辑 `configs/projects.json`，为项目添加 `push_server` 配置，确保启用 `enabled:true`，并正确填写 `webhook_url` (例如 `http://74.176.37.71:8080/webhook`)。

5. **一键配置所有内核仓库**  
   - 仓库 Actions 页面，运行 `1. Setup Kernel Repositories` 工作流，自动配置所有项目的 CI 触发器和 Webhook。

### 如何添加新项目

1. 运行 `0. Add New Kernel Project` 工作流，在表单中**使用英文逗号 (`,`) 分隔**每一项信息。
2. 工作流自动修改 `projects.json` 和相关文件。
3. 新项目仓库添加 `CI_TOKEN` Secret。
4. 再次运行 `1. Setup Kernel Repositories`，自动配置触发器和 Webhook。

### 日常使用

- **内核开发与测试：**  
  推送到指定分支将自动触发**测试构建** (标记为 pre-release)。您也可以手动运行 `4. Universal Kernel Builder` 工作流进行自定义构建。commit message 包含 `[skip ci]` 可跳过构建。

- **正式版发布 (一键操作)：**
  运行 `6. Release All Branches` 工作流，选择目标项目。系统会自动为该项目的所有存在的分支并行构建，并发布为**正式版 Release**。

- **推送服务器开发：**  
  修改 `push_server/` 目录下文件并推送，`5. Deploy Push Server` 工作流将自动部署应用到服务器并重启服务。

---

## 核心组件详解

### 1. `configs/projects.json` - 项目大脑
定义每一个内核项目及其推送服务配置。

### 2. `push_server/` - 推送服务应用
- `app.py`：Flask 机器人核心逻辑，集成结构化日志。
- `config.json`：配置模板，机密信息由部署流自动注入。
- `requirements.txt`：Python依赖清单。

### 3. `.github/workflows/` - 自动化工作流
- `0-add-new-project.yml`：**(推荐)** 一键式交互向导，用于向 CI 中心添加新的内核项目。
- `1-setup-kernel-repos.yml`：**一键式** 初始化/同步所有内核仓库的配置，包括 CI 触发器和 Webhook。
- `2-update-kernelsu.yml`：**手动** 为指定的项目和分支更新 KernelSU 源码。
- `3-upstream-watcher.yml`：**自动** 监视上游 KernelSU 仓库的更新。
- `4-universal-build.yml`：**通用构建调度器**，接收手动或自动触发，并调用可复用的构建任务。
- `5-deploy-push-server.yml`：**推送服务部署流**，当 `push_server/` 目录更新时，自动将应用部署到您的服务器。
- `6-release-all-branches.yml`：**一键发布流**，为指定项目的所有分支构建并发布正式版 Release。
- `reusable-build-job.yml`：**可复用的构建引擎**，包含所有核心的编译和发布逻辑。
- `reusable-update-kernel-source.yml`：**可复用的源码更新引擎**，用于更新内核仓库中的 KernelSU。

---

## 贡献指南

欢迎参与开发！  
1. Fork 本项目，提交 PR 前请确保代码符合 Python 代码规范（建议使用 `black` 和 `flake8`）。  
2. 每个功能请单独提交 PR，详细描述变更内容。  
3. 有建议或问题，欢迎通过 Issues 或 Discussions 反馈。

---

## 常见问题 FAQ

<details>
<summary>Q: 如何跳过某次构建？</summary>
A: 在 commit message 中包含 `[skip ci]`。
</details>

<details>
<summary>Q: 如何自定义推送服务器？</summary>
A: 编辑 `configs/projects.json`，配置 `push_server` 块。
</details>

更多问题欢迎通过 Discussions 交流。

---

## 联系方式

- Telegram: [@YuzakiKokuban](https://t.me/YuzakiKokuban)
- Email: heibanbaize@gmail.com

---

> 如需架构图或更详细的技术细节，请查阅 [Wiki](https://github.com/YuzakiKokuban/Kokuban_Kernel_CI_Center/wiki)。
