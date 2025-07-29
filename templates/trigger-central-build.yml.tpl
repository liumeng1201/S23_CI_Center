# 由中央 CI 系统自动生成和管理
# 请勿手动修改此文件
name: Trigger Central Build
on:
  push:
    branches: [ sukisuultra, mksu, ksu ]
jobs:
  trigger:
    runs-on: ubuntu-latest
    steps:
      - name: Trigger build in kernel-ci repository
        uses: peter-evans/repository-dispatch@v3
        with:
          repository: __REPO_OWNER__/Kokuban_Kernel_CI_Center
          token: ${{ secrets.CI_TOKEN }}
          event-type: build-kernel
          client-payload: >-
            {
              "project": "__PROJECT_KEY__",
              "branch": "${{ github.ref_name }}"
            }
