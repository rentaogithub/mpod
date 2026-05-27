# cocoapods-podx 使用说明

`cocoapods-podx` 是面向 iOS 工程的 AI 指令服务：在不修改主工程 `Podfile` 的情况下管理组件本地/远端切换，同时覆盖需求分析、开发影响分析、依赖治理、测试验证、发布和 AI 规则/技能/代理/MCP 的持续演进。未写入 `Podfile.overlay` 的组件默认继续走远端仓库。

## 新电脑安装

在主工程目录执行：

```bash
sh tools/cocoapods-podx.sh install
```

脚本会自动完成：

- 从配置的 gem 源查询当前最新的 `cocoapods-podx-*.gem`
- 下载 gem 包
- 找到当前 `pod` 命令对应的 CocoaPods gem 环境；如果没有 CocoaPods，则进入 publish-only 模式并安装到当前用户 RubyGems 环境
- 安装或重新安装 `cocoapods-podx`

安装完成后验证：

```bash
podx version
podx help
```

`podx help` 会根据当前目录动态显示帮助：Podfile 管理工程会展示 pod、overlay、mgit 和发布能力；非 Podfile 工程会展示可用的 `podx publish --job ...` 和 `mgit` 命令。

没有安装 CocoaPods 的机器也可以只安装 publish-only 模式，用于触发指定发布任务、执行 `podx ai` 初始化 AI 辅助文件，或执行 `mgit` 多仓库 git 命令：

```bash
sh tools/install-cocoapods-podx.sh
podx publish --job JOB_NAME --branch develop
```

publish-only 模式会自动把 `~/.local/bin` 写入当前脚本环境，并同步到已存在的常见 shell 配置：`~/.zshrc`、`~/.zprofile`、`~/.bash_profile`、`~/.bashrc`、`~/.profile`；如果这些文件都不存在，则创建 `~/.zshrc`。如果当前终端仍找不到 `podx` 或 `mgit`，重新打开终端即可。该模式支持 `podx publish --job ...`、`podx ai ...` 和全部 `mgit` 命令；不支持 `podx install/update/doctor/open/main` 和组件本地/远端切换。

如果需要安装指定版本：

```bash
sh tools/cocoapods-podx.sh install 0.0.1
```

也可以通过环境变量指定版本：

```bash
COCOAPODS_PODX_VERSION=0.0.1 sh tools/cocoapods-podx.sh install
```

如果 gem 源地址或账号需要临时调整：

```bash
COCOAPODS_PODX_GEM_SOURCE="GEM_SOURCE_URL" \
COCOAPODS_PODX_NEXUS_USER="USER" \
COCOAPODS_PODX_NEXUS_PASSWORD="PASSWORD" \
sh tools/cocoapods-podx.sh install
```

注意：直接执行 `gem list cocoapods-podx` 查询的是当前 shell 的默认 RubyGems 环境，不一定是 `pod` 命令使用的 CocoaPods gem 环境。建议使用下面命令确认：

```bash
podx version
```

## 常用命令

命令入口按语义拆分：

- `podx 新增命令`：本地/远端切换、发布、打开工程等增强能力。
- `pod 命令`：`podx install`、`podx repo update`、`podx init`、`podx update` 等按官方 CocoaPods 语义执行，必要时附加 overlay 前置处理。
- `mgit`：多仓库 git 命令，包括 branch、status、diff、log、add、pull、push、commit、publish。
- `pod`：原生 CocoaPods 命令保持不变。

冲突规则：`podx` 遇到同名命令时优先执行插件语义；需要原生 CocoaPods 行为时，直接使用 `pod` 命令。

```bash
podx update NNBussCom            # 官方 pod update；命中本地组件时先更新本地仓库
podx install --no-repo-update    # 原生 pod install
podx repo update                 # 原生 pod repo update
pod update RxSwift               # 原生 CocoaPods 命令
```

```bash
podx 新增命令：
podx                             # 查看支持切换的内部组件范围
podx NNBussCom                   # 将组件切到本地；本地缺失时自动 clone，分支不一致时自动切换
podx disable NNBussCom           # 将组件切回远端
podx disable                     # 全部切回远端
podx main                        # 查看主 Podfile 中的 npod 配置
podx publish                     # 当前分支触发默认发布渠道
podx publish tf                  # 当前分支触发 TestFlight 发布
podx publish app                 # 当前分支触发苹果商店发布
podx publish --job JOB_NAME      # 指定发布任务
podx publish tf --branch release/5.14.2 # 指定 release 分支发布 TestFlight
podx publish app --branch release/5.14.2 # 指定 release 分支发布 APP Store
podx dry-run publish app         # 预览发布参数，不触发构建
podx list                        # 查看 overlay 组件的 local/remote 状态
podx dry-run NNBussCom           # 预览 overlay 写入、本地仓库路径、远端地址、目标分支和 clone/checkout/pull 动作
podx dry-run disable             # 预览全部切回远端，不修改 Podfile.overlay
podx dry-run update              # 预览本地组件分支切换和 pull 动作，不 checkout 或 pull
podx doctor                      # 检查插件接入、配置和本地组件状态
podx version                     # 查看当前 cocoapods-podx 插件版本
podx upgrade                     # 升级 cocoapods-podx 到 Nexus 最新版本
podx upgrade 0.0.42              # 升级 cocoapods-podx 到指定版本
podx open                        # 打开当前工程 .xcworkspace
podx open --overlay              # 打开 Podfile.overlay，文件不存在时先创建模板
podx hooks install               # 展示团队规则，并安装 Git 提交保护 hook
podx ai init                     # 生成 Claude Code/CodeGraph/Code Review Graph 接入模板
podx ai update                   # 更新 CodeGraph，并检查 Code Review Graph 改动影响
podx ai doctor                   # 检查 AI 辅助工具状态
podx ai memory                   # 查看 Hermes 记忆使用说明和状态
podx ai mcp                      # 输出 Hermes MCP 注册说明
podx help                        # 查看中文帮助

高阶意图命令：
podx workon NNBussCom            # 开始开发组件，等同 podx NNBussCom
podx dev NNBussCom               # 同 podx workon
podx check                       # 检查工程接入、配置和本地组件状态，等同 podx doctor
podx health                      # 同 podx check
podx graph                       # 更新 AI 图谱并检查改动影响，等同 podx ai update
podx tools                       # 检查 rg/fd/bat/jq/yq/delta/ast-grep/ctags/htop 等现代 CLI
podx ship tf --branch release/5.14.2 # 发布意图入口，等同 podx publish tf --branch release/5.14.2
podx ship dry-run app --branch release/5.14.2 # 预览发布参数，等同 podx dry-run publish app
podx diagnose 1203               # 分析 Jenkins 打包失败，等同 podx publish doctor 1203
podx repair 1203                 # 半自动修复 Jenkins 打包失败，等同 podx publish fix 1203

pod 命令：
podx install --no-repo-update    # 执行官方 pod install --no-repo-update
podx repo update                 # 执行官方 pod repo update
podx init                        # 执行官方 pod init，并生成 podx.config.yml
podx update NNBussCom            # 执行官方 pod update；命中本地组件时先更新本地仓库

mgit 多仓库 git 命令：
mgit branch                      # 组合查看 git branch
mgit branch NNBussCom            # 查看单个组件分支
mgit checkout NNBussCom release/5.14.2 # 只切换指定组件仓库分支
mgit stash NNBussCom             # 只 stash 指定组件仓库
mgit status                      # 组合查看 git status --short
mgit diff                        # 组合查看 git diff
mgit log                         # 组合查看最近 5 条 git log
mgit log --limit=10              # 组合查看最近 10 条 git log
mgit add                         # 组合执行 git add -A
mgit pull                        # 组合执行 git pull --ff-only
mgit push                        # 组合执行 git push
mgit commit -m "msg"             # 组合提交主工程和当前本地组件仓库
mgit commit -m "msg" -edit Podfile.rb # 显式允许提交受保护文件
mgit publish release/5.14.2      # 多仓库发布分支：从 develop 创建/更新并推送
mgit dry-run checkout release/5.14.2 # 预览切换分支
mgit dry-run stash                # 预览 stash 动作
mgit dry-run publish release/5.14.2 # 预览多仓库发布分支创建和推送动作
mgit dry-run add                 # 预览哪些仓库会执行 git add
mgit dry-run pull                # 预览哪些仓库会执行 git pull
mgit dry-run push                # 预览哪些仓库会执行 git push
mgit dry-run commit              # 预览哪些仓库会被组合提交，不执行 git add 或 commit
```

日常使用 `podx` 和 `mgit` 即可。

## 发布

`podx publish` 不打包本地未提交代码。未指定 `--branch` 时，只读取当前主工程 git 分支名，并以 `origin/<当前分支>` 传给发布服务，实际打包的是远端分支 HEAD。

```bash
podx publish
podx publish tf
podx publish app
podx publish --job JOB_NAME
podx publish --job JOB_NAME --branch develop
podx publish tf --branch release/5.14.2
podx publish app --branch origin/release/5.14.2
```

`podx publish` 会按发布任务的参数配置决定支持的任务类型。

非 Podfile 工程执行 `podx publish` 时必须指定发布任务名，例如 `JOB_NAME`。发布服务地址和认证信息由本地配置、环境变量或 CI/CD 平台提供，不写入文档。

TestFlight 和苹果商店包只允许发布 `release/x.x.x` 分支。未指定 `--branch` 时会使用当前分支名对应的远端分支；指定时支持 `release/5.14.2` 或 `origin/release/5.14.2`。

触发前会显示发布分支、发布渠道和远端打包版本表格。触发成功后，队列、构建号、关键日志进度会在终端单行刷新；最终只保留打包结果。失败时输出关键错误行；如果任务被手动中断，会提示打包任务已取消。

## 多仓库发布分支

```bash
mgit dry-run publish release/5.14.2
mgit publish release/5.14.2
```

`mgit publish` 默认从 `develop` 创建或更新目标分支，并推送 `podx.config.yml` 中 `publish_repos` 声明的仓库。默认工作目录是主工程下的 `.mgit-publish`。

默认情况下，`mgit publish` 只做通用多仓库分支发布，不会修改 `Podfile`，也不会修改 Xcode 版本号。只有显式配置 `publish_main_repo`、`publish_update_podfile_branch` 和 `publish_version.type: ios_xcodeproj` 后，才会开启 iOS 工程定制动作。

插件会优先读取 `podx.config.yml`，旧工程中的 `Podfile.overlay.config.yml` 仍会作为兼容 fallback 读取；新工程建议只保留 `podx.config.yml`。

发布配置示例：

```yaml
publish_work_dir: .mgit-publish
publish_base_branch: develop
publish_main_repo: nnios
publish_update_podfile_branch: true
publish_repos:
  - nnios
  - nnbusscom
  - name: custom_repo
    url: GIT_REPO_URL
publish_version:
  type: ios_xcodeproj
  branch_pattern: '^release/(\d+\.\d+\.\d+)$'
  project_file: NNIM.xcodeproj/project.pbxproj
  build_number_strategy: ios_semver
```

```bash
mgit publish release/5.14.2 --base-branch develop --push-mode normal
mgit publish release/5.14.2 --push-mode skip
mgit publish release/5.14.2 --push-mode set-upstream
mgit publish release/5.14.2 --publish-work-dir /tmp/nn-publish
```

## 本地组件切换

切换单个组件到本地源码：

```bash
podx NNBussCom
pod install --no-repo-update
```

切换多个组件到本地源码：

```bash
podx NNBussCom NNBasciCommon NNLibrary
pod install --no-repo-update
```

切回远端：

```bash
podx disable NNBussCom
pod install --no-repo-update
```

全部切回远端：

```bash
podx disable
pod install --no-repo-update
```

## Podfile.overlay

`Podfile.overlay` 与主工程 `Podfile` 同级，只声明哪些内部组件使用本地源码：

```ruby
npod 'NNBussCom'
npod 'NNBasciCommon'
npod 'NNLibrary'
```

规则：

1. `npod 'XXX'` 表示该组件使用本地仓库。
2. 不在 `Podfile.overlay` 中的内部组件默认使用远端仓库。
3. `Podfile.overlay` 中不要写 `branch`、`localWork` 或其他参数。
4. `Podfile.overlay` 中的组件必须能在主 `Podfile` 的 `npod` 声明中找到。

本地组件统一放在主工程目录下：

```text
Development Pods/
  nnbascicommon/
  nnbusscom/
  nnlibrary/
```

如果 `Podfile.overlay` 中声明的本地组件目录不存在，执行 `pod install` 或 `podx 组件名` 时会自动 clone。

## 推荐流程

```bash
podx main
podx NNBussCom
mgit branch
pod install --no-repo-update
```

联调结束：

```bash
podx disable NNBussCom
pod install --no-repo-update
```

## 排查命令

查看插件版本：

```bash
podx version
```

卸载插件：

```bash
sh tools/cocoapods-podx.sh uninstall
```

检查插件和工程配置：

```bash
podx doctor
```

检查本地组件分支：

```bash
podx doctor
mgit branch
```

更新本地组件：

```bash
podx update NNBussCom
```

组合提交主工程和当前本地组件：

```bash
mgit status
mgit diff
mgit dry-run add
mgit add
mgit dry-run commit
mgit commit -m "feat: update local components"
mgit dry-run push
mgit push
```

只提交指定本地组件：

```bash
mgit status NNBussCom NNBasciCommon
mgit diff NNBussCom NNBasciCommon
mgit add NNBussCom NNBasciCommon
mgit commit NNBussCom NNBasciCommon -m "feat: update components"
mgit push NNBussCom NNBasciCommon
```

还能继续支持的 git 命令建议：

- `stash` / `stash pop`：组合暂存和恢复本地改动，但风险比 status/add 更高。
- `reset`：不建议默认支持，容易误删本地改动。
