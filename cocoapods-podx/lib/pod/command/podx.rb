require 'set'
require 'fileutils'
require 'open3'
require 'yaml'
require_relative '../../cocoapods_podx/commands/git_actions'
require_relative '../../cocoapods_podx/commands/git_hooks'
require_relative '../../cocoapods_podx/commands/dependency_report'
require_relative '../../cocoapods_podx/commands/skill_runtime'
require_relative '../../cocoapods_podx/commands/pipeline_runtime'
require_relative '../../cocoapods_podx/commands/jenkins_publish'
require_relative '../../cocoapods_podx/commands/overlay_file'
require_relative '../../cocoapods_podx/commands/mgit_publish'
require_relative '../../cocoapods_podx/ai_bootstrap'
require_relative '../../cocoapods_podx/shim_generator'

class Pod::Command::Podx < Pod::Command
  include CocoapodsPodx::Commands::GitActions
  include CocoapodsPodx::Commands::GitHooks
  include CocoapodsPodx::Commands::DependencyReport
  include CocoapodsPodx::Commands::SkillRuntime
  include CocoapodsPodx::Commands::PipelineRuntime
  include CocoapodsPodx::Commands::JenkinsPublish
  include CocoapodsPodx::Commands::OverlayFile
  include CocoapodsPodx::Commands::MgitPublish

  self.summary = '创建或更新 Podfile.overlay，用于切换私有组件本地/远端依赖。'
  self.description = <<~DESC
    在主 Podfile 同级目录创建或更新 Podfile.overlay。
    `pod 'PodName'` 表示本地。
    不在 Podfile.overlay 中的组件默认走远端。

      Usage:

      pod 命令:

            podx install [OPTIONS]         安装 Pods，等同 pod install；支持 --repo-update
            podx repo update [OPTIONS]     更新 Specs 仓库，等同 pod repo update
            podx init [OPTIONS]            一键初始化工程配置、规则、技能、流程、AI 上下文和 hooks
            podx sync                      同步团队规则、技能、流程、AI 上下文和 hooks
            podx update [NAME] [OPTIONS]   更新 Pod；命中本地组件时先更新本地仓库
            podx clean NAME                清理指定组件 pod cache，并删除 Pods/NAME

      pod 扩展命令:

            podx [NAME]                    将组件切到本地源码
            podx disable [NAME]            将组件切回远端；不传 NAME 表示全部切回远端
            podx main                      查看主 Podfile 中的内部组件 pod 配置
            podx deps                      查看主工程依赖组件分支/版本和组件依赖关系
            podx doctor                    检查插件接入、配置和本地组件状态
            podx rules                     查看当前工程规则器规则
            podx rules check               检查 .gitignore 是否符合规则器治理
            podx rules sync                补齐 .gitignore 中缺失的本地产物规则
            podx rules snapshot            生成 .podx/rules_snapshot.json 规则快照
            podx rules ci                  CI 门禁：生成规则快照，失败时返回非 0
            podx pipeline                  查看团队 CI/CD 能力地图
            podx pipeline flow             查看开发/发布主流程
            podx pipeline ci               查看团队 CI 门禁模板
            podx pipeline script           生成 .podx/pipeline_ci.sh，内置快照/报告/总门禁
            podx pipeline doctor           检查团队 CI 脚本是否存在、可执行且与模板一致
            podx pipeline snapshot         生成 .podx/pipeline_snapshot.json
            podx pipeline report           生成 .podx/pipeline_report.md
            podx pipeline status           汇总 rules/skill/pipeline 产物状态
            podx pipeline gate             CI 总门禁：汇总产物状态，失败时返回非 0
            podx pipeline policy           查看发布渠道门禁策略
            podx pipeline readiness        按当前门禁和策略评估各渠道发布准入
            podx skill list [KEYWORD]      查看/筛选团队 iOS DevOps skill library
            podx skill init                生成工程级 .podx/skills.yml
            podx skill show NAME           查看 skill 详情和执行步骤
            podx skill history [N]         查看最近 N 次 skill 执行记录
            podx skill stats               查看 skill 运行统计
            podx skill report              查看 skill runtime 治理总览
            podx skill suggest             根据治理状态给出下一步建议
            podx skill snapshot            生成 Markdown 治理快照
            podx skill ci                  CI 校验 skill library，并生成 Markdown/JSON 治理报告
            podx skill ci strict           严格 CI 门禁，report fail 也会失败
            podx skill doctor              体检团队 skill library 可用性
            podx skill graph               查看 skill 依赖关系
            podx skill plan NAME           展开 skill 执行计划，不执行任务
            podx skill lint                检查 skill library 定义规范
            podx skill verify NAME         校验 skill 前置条件，不执行任务
            podx skill run NAME            执行已验证的浅层 skill
            podx publish [pgyer|tf|app]    触发 Jenkins 发布；默认 nn job 支持蒲公英/TestFlight/AppStore
            podx publish --branch=develop  指定远端分支发布；也支持 --branch develop
            podx publish --job JOB         指定 Jenkins job 名；按该 job 参数能力发布
            podx publish --job nnrtc-ios-build
                                           触发 nnrtc-ios-build 打 Framework
            podx publish tf --branch=release/x.x.x
                                           指定 release 分支发布 TestFlight
            podx publish app --branch=release/x.x.x
                                           指定 release 分支发布 APP Store
            podx publish history [N]       查看 Jenkins 最近 N 次构建；默认 10 次
            podx publish log [BUILD]       查看 Jenkins 构建日志；不传 BUILD 默认 lastBuild
            podx publish doctor [BUILD]    分析 Jenkins 打包失败原因；默认 lastBuild
            podx publish fix [BUILD]       半自动修复低风险打包失败；执行前确认
            podx publish --pipeline-gate   发布前执行 pipeline 总门禁
            podx publish --force-private-pod-update
                                           强制 Jenkins 更新私有 Pod 依赖
            podx dry-run <command>         预览 publish、update、组件切换等动作
            podx open                      打开当前工程 .xcworkspace
            podx open --overlay            打开 Podfile.overlay
            podx ai init                   生成 Claude Code/CodeGraph/Code Review Graph 接入模板
            podx ai update                 更新 CodeGraph，并检查 Code Review Graph 改动影响
            podx ai doctor                 检查 AI 辅助工具状态
            podx ai mcp                    输出 Hermes MCP 注册说明
            podx hooks install             安装版本化提交保护 hook
            podx version                   查看当前插件版本

      git 命令:

            mgit branch [NAME]             组合查看 git branch
            mgit checkout BRANCH           组合切换本地组件仓库分支
            mgit checkout [NAME] BRANCH    只切换指定组件仓库分支
            mgit checkout -b BRANCH        组合创建并切换本地新分支
            mgit merge [NAME] BRANCH       合并来源分支到当前同名分支组件仓库
            mgit stash [NAME]              组合执行 git stash push -u
            mgit stash list [NAME]         查看 stash 列表
            mgit stash apply NAME          只恢复指定仓库 stash，不提供全量 apply/pop
            mgit status [NAME]             组合查看 git status --short
            mgit diff [NAME]               组合查看 git diff
            mgit log [NAME]                组合查看最近 5 条 git log
            mgit add [NAME]                组合执行 git add -A；mgit add . / -A 等同全量 add
            mgit pull [NAME]               组合执行 git pull --rebase
            mgit pull --ff-only [NAME]     组合执行 git pull --ff-only
            mgit rebase --continue         继续当前冲突修复后的 rebase
            mgit rebase --abort            放弃当前 rebase
            mgit push [NAME]               组合执行 git push
            mgit commit [NAME] -m "msg"    组合提交主工程和本地组件仓库
            mgit commit -m "msg" -edit Podfile
            mgit publish release/x.x.x     从 develop 创建/更新多仓库发布分支并推送
  DESC
  self.arguments = [
    CLAide::Argument.new('POD_NAME ...', false)
  ]

  def self.options
    [
      ['--main', '查看主 Podfile 中的组件配置。'],
      ['--deps', '查看主工程依赖组件分支/版本和组件依赖关系。'],
      ['--rules', '查看当前工程规则器规则；支持 check/sync/snapshot/ci 子命令。'],
      ['--pipeline', '查看团队 CI/CD 能力地图；支持 flow、ci、script、doctor、snapshot、report、status、gate、policy、readiness 子命令。'],
      ['--skill', '执行 skill runtime 命令：list、show、history、stats、report、suggest、snapshot、ci、doctor、graph、plan、lint、verify、run；ci 支持 strict 模式。'],
      ['--list', '查看 overlay 组件的 local/remote 状态。'],
      ['--create-overlay-file', '创建 Podfile.overlay 模板，并加入 Xcode 工程引用。'],
      ['--update', '更新 Podfile.overlay 中命中的本地组件仓库；podx update 会随后执行原生 pod update。'],
      ['--clean', '清理指定组件 pod cache，并删除 Pods/NAME。'],
      ['--checkout', '组合执行 git checkout BRANCH。'],
      ['--stash', '组合执行 git stash push -u。'],
      ['--status', '组合查看 git status --short。'],
      ['--diff', '组合查看 git diff。'],
      ['--log', '组合查看 git log。'],
      ['--limit=N', 'git log 显示条数，默认 5。'],
      ['--add', '组合执行 git add -A；额外的 .、-A、--all 会按全量 add 处理。'],
      ['--pull', '组合执行 git pull --rebase。'],
      ['--rebase', '搭配 --pull 使用，执行 git pull --rebase；当前为默认行为。'],
      ['--ff-only', '搭配 --pull 使用，执行 git pull --ff-only。'],
      ['--push', '组合执行 git push。'],
      ['--commit', '组合提交主工程和当前本地组件仓库。'],
      ['--edit=FILE', 'mgit commit 显式允许提交受保护文件，例如 Podfile。'],
      ['--git-publish', '按多仓库发布流程创建/更新目标分支；供 mgit publish 使用。'],
      ['--base-branch=BRANCH', 'mgit publish 使用的基准分支，默认 develop。'],
      ['--push-mode=MODE', 'mgit publish 推送模式：normal、skip、set-upstream，默认 normal。'],
      ['--publish-work-dir=DIR', 'mgit publish 克隆和处理仓库的工作目录，默认 .mgit-publish。'],
      ['--publish', '触发 Jenkins 发布任务；默认蒲公英，渠道支持 pgyer/pgy、tf/testflight、app/appstore。'],
      ['--jenkins-history', '查看 Jenkins 最近构建列表；可传数量，默认 10，最大 50。'],
      ['--jenkins-log', '查看 Jenkins 构建日志；构建号可传数字或 lastBuild。'],
      ['--jenkins-doctor', '分析 Jenkins 打包失败原因；构建号可传数字或 lastBuild。'],
      ['--jenkins-fix', '半自动修复低风险 Jenkins 打包失败；执行前确认。'],
      ['--fix-job=JOB', '半自动修复时触发 Jenkins 维护 job，例如 podx-upgrade。'],
      ['--job=JOB', '指定 Jenkins job 名，例如 nnrtc-ios-build；会自动使用默认 Jenkins 主备地址。'],
      ['--jenkins-job=JOB', '同 --job。'],
      ['--jenkins-url=URL', 'Jenkins 发布任务地址；默认优先 http://10.1.3.177:8080/job/nn/，失败后切到 http://10.1.107.211:8080/job/nn/。'],
      ['--branch=BRANCH', '指定 Jenkins 发布远端分支；tf/app 必须是 release/x.x.x，等同 --publish-branch。'],
      ['--publish-branch=BRANCH', '指定 Jenkins 发布远端分支；tf/app 必须是 release/x.x.x。'],
      ['--publish-password=PASSWORD', 'Jenkins 发布验证密码；默认交互输入 TestFlight/AppStore 密码，Pgyer 默认空。'],
      ['--notify-wechat=BOOL', '控制 Jenkins 企业微信机器人通知，支持 true/false。'],
      ['--no-wechat-notify', '关闭 Jenkins 企业微信机器人通知，等同 --notify-wechat=false。'],
      ['--force-private-pod-update=BOOL', '传递 Jenkins FORCE_PRIVATE_POD_UPDATE 参数，支持 true/false；不带值默认 true。'],
      ['--no-force-private-pod-update', '传递 Jenkins FORCE_PRIVATE_POD_UPDATE=false。'],
      ['--pipeline-gate', 'podx publish 触发 Jenkins 前执行 pipeline 总门禁。'],
      ['--no-pipeline-gate', 'podx publish 临时跳过 pipeline 总门禁。'],
      ['--no-publish-lock', 'podx publish 临时跳过本地并发锁，允许同一工程并行触发。'],
      ['--lines=N', '查看 Jenkins 日志时只显示最后 N 行。'],
      ['--no-hermes', '分析 Jenkins 打包失败时跳过 Hermes 二次分析。'],
      ['--yes', '半自动修复时跳过确认。'],
      ['-m MSG', '组合提交使用的 git commit message。'],
      ['--message=MSG', '兼容旧写法；推荐使用 -m。'],
      ['--dry-run', '预览将要执行的写入、切分支或更新动作，不修改文件或仓库。'],
      ['--doctor', '检查 Podfile、配置文件、Podfile.overlay 和本地组件仓库状态。'],
      ['--version', '查看当前 cocoapods-podx 插件版本。'],
      ['--init', '一键初始化工程配置、规则、技能、流程、AI 上下文和 hooks。'],
      ['--sync', '同步团队规则、技能、流程、AI 上下文和 hooks。'],
      ['--ai', '执行 AI 辅助初始化命令：init、update、doctor、mcp。'],
      ['--hooks', '执行 Git hook 辅助命令：install。'],
      ['--open', '打开当前工程 .xcworkspace；配合 --overlay 打开 Podfile.overlay。'],
      ['--overlay', 'podx open --overlay 使用，打开 Podfile.overlay。'],
      ['--install-command-shims', '重新生成 podx/mgit 快捷命令，并清理旧快捷命令。'],
      ['--disable', '切远端；本质是从 Podfile.overlay 中移除。'],
    ].concat(super)
  end

  def initialize(argv)
    @project_directory = argv.option('project-directory')
    @main_mode = argv.flag?('main', false)
    @deps_mode = argv.flag?('deps', false)
    @rules_mode = argv.flag?('rules', false)
    @pipeline_mode = argv.flag?('pipeline', false)
    @skill_mode = argv.flag?('skill', false)
    @list_mode = argv.flag?('list', false)
    @create_overlay_file_mode = argv.flag?('create-overlay-file', false)
    @git_branch_mode = argv.flag?('git-branch', false)
    @checkout_mode = argv.flag?('checkout', false)
    @stash_mode = argv.flag?('stash', false)
    @update_mode = argv.flag?('update', false)
    @clean_mode = argv.flag?('clean', false)
    @status_mode = argv.flag?('status', false)
    @diff_mode = argv.flag?('diff', false)
    @log_mode = argv.flag?('log', false)
    @log_limit = argv.option('limit') || '5'
    @add_mode = argv.flag?('add', false)
    @pull_mode = argv.flag?('pull', false)
    @pull_ff_only = argv.flag?('ff-only', false)
    @push_mode = argv.flag?('push', false)
    @commit_mode = argv.flag?('commit', false)
    @git_publish_mode = argv.flag?('git-publish', false)
    @git_publish_base_branch = argv.option('base-branch')
    @git_publish_push_mode = argv.option('push-mode') || 'normal'
    @git_publish_work_dir = argv.option('publish-work-dir')
    @publish_mode = argv.flag?('publish', false)
    @jenkins_history_mode = argv.flag?('jenkins-history', false)
    @jenkins_log_mode = argv.flag?('jenkins-log', false)
    @jenkins_doctor_mode = argv.flag?('jenkins-doctor', false)
    @jenkins_fix_mode = argv.flag?('jenkins-fix', false)
    @jenkins_job = argv.option('job') || argv.option('jenkins-job')
    @jenkins_fix_job = argv.option('fix-job')
    @jenkins_url = argv.option('jenkins-url')
    @publish_branch = argv.option('branch') || argv.option('publish-branch')
    @publish_password = argv.option('publish-password')
    @notify_wechat = argv.option('notify-wechat')
    wechat_notify_flag = argv.flag?('wechat-notify')
    @notify_wechat = wechat_notify_flag.to_s unless wechat_notify_flag.nil?
    @force_private_pod_update = argv.option('force-private-pod-update')
    force_private_pod_update_flag = argv.flag?('force-private-pod-update')
    @force_private_pod_update = force_private_pod_update_flag.to_s unless force_private_pod_update_flag.nil?
    @publish_pipeline_gate = argv.flag?('pipeline-gate', false)
    @skip_publish_pipeline_gate = argv.flag?('no-pipeline-gate', false)
    @skip_publish_lock = argv.flag?('no-publish-lock', false)
    @jenkins_log_lines = argv.option('lines')
    @jenkins_history_limit = argv.option('limit')
    @jenkins_hermes_analysis = !argv.flag?('no-hermes', false)
    @assume_yes = argv.flag?('yes', false)
    @commit_message = argv.option('m') || argv.option('message')
    @protected_edit_files = [argv.option('edit')].compact
    @stash_message = argv.option('m') || argv.option('message')
    @dry_run = argv.flag?('dry-run', false)
    @doctor_mode = argv.flag?('doctor', false)
    @version_mode = argv.flag?('version', false)
    @init_mode = argv.flag?('init', false)
    @sync_mode = argv.flag?('sync', false)
    @ai_mode = argv.flag?('ai', false)
    @hooks_mode = argv.flag?('hooks', false)
    @open_mode = argv.flag?('open', false)
    @open_overlay_mode = argv.flag?('overlay', false)
    @install_command_shims_mode = argv.flag?('install-command-shims', false)
    @disable = argv.flag?('disable', false)
    @pod_names = argv.arguments! || []
    @pod_names = @pod_names.map(&:strip).reject(&:empty?)
    normalize_git_add_arguments!
    extract_commit_message_from_arguments!
    extract_protected_edit_files_from_arguments!
    extract_checkout_branch_from_arguments!
    super
  end

  def validate!
    super
    return if @version_mode
    return if @ai_mode
    return if @hooks_mode
    return if @open_mode
    return if @install_command_shims_mode
    return if @publish_mode
    return if @jenkins_history_mode
    return if @jenkins_log_mode
    return if @jenkins_doctor_mode
    return if @jenkins_fix_mode
    return if @pipeline_mode
    return if @skill_mode
    help! '当前目录或指定目录下未找到 Podfile。' unless File.exist?(podfile_path)
    return if @git_publish_mode
    return if @update_mode
    return if @clean_mode
    return if @deps_mode
    return if @rules_mode
    return if @create_overlay_file_mode
    return if @list_mode
    return if @pod_names.empty?

    validate_target_names!
  end

  def run
    unless internal_podx_invocation?
      Pod::UI.puts 'pod podx 是 cocoapods-podx 的内部入口，请使用 podx 或 mgit。'
      Pod::UI.puts '示例：podx update NNBussCom'
      Pod::UI.puts '示例：podx open --overlay'
      Pod::UI.puts '示例：mgit status'
      return
    end

    if @version_mode
      show_plugin_version
      return
    end

    if @ai_mode
      CocoapodsPodx::AiBootstrap.run(@pod_names, project_directory: ai_project_directory)
      return
    end

    if @hooks_mode
      run_hooks_command(load_entries)
      return
    end

    if @skill_mode
      run_skill_command(load_entries)
      return
    end

    if @open_mode
      open_project_resource
      return
    end

    if @clean_mode
      clean_pod_cache_and_installed_pods
      return
    end

    if @install_command_shims_mode
      install_command_shims(detect_cocoapods_gem_home)
      return
    end

    if @publish_mode
      publish_to_jenkins
      return
    end

    if @jenkins_history_mode
      @jenkins_history_limit ||= @pod_names.first
      show_jenkins_build_history
      return
    end

    if @jenkins_log_mode
      @jenkins_log_build = @pod_names.first
      show_jenkins_build_log
      return
    end

    if @jenkins_doctor_mode
      @jenkins_log_build = @pod_names.first
      doctor_jenkins_build
      return
    end

    if @jenkins_fix_mode
      @jenkins_log_build = @pod_names.first
      fix_jenkins_build
      return
    end

    entries = load_entries

    if @git_branch_mode
      show_branch_info
      return
    end

    if @main_mode
      show_main_config
      return
    end

    if @deps_mode
      show_dependency_report
      return
    end

    if @rules_mode
      run_rules_command
      return
    end

    if @pipeline_mode
      show_pipeline_map
      return
    end

    if @list_mode
      show_overlay_list(entries)
      return
    end

    if @create_overlay_file_mode
      create_overlay_file
      return
    end

    if @update_mode
      update_local_repos(entries)
      return
    end

    if @checkout_mode || @stash_mode || @status_mode || @diff_mode || @log_mode || @add_mode || @pull_mode || @push_mode
      git_action_repos(entries)
      return
    end

    if @commit_mode
      commit_repos(entries)
      return
    end

    if @git_publish_mode
      publish_git_branches
      return
    end

    if @doctor_mode
      doctor_overlay(entries)
      return
    end

    if @init_mode
      init_project('init')
      return
    end

    if @sync_mode
      init_project('sync')
      return
    end

    if @disable && @pod_names.empty?
      @pod_names = supported_overlay_names
    end

    if @pod_names.empty?
      Pod::UI.puts '当前支持的 overlay 组件范围：'
      supported_overlay_names.each { |name| Pod::UI.puts "- #{name}" }
      return
    end

    if @dry_run
      preview_write_entries(entries)
      preview_prepare_local_repos unless @disable
    else
      prepare_local_repos(@pod_names) unless @disable
      write_entries(entries)
      Pod::UI.puts 'Podfile.overlay [updated]'
    end
  end

  private

  def internal_podx_invocation?
    ENV['COCOAPODS_PODX_INTERNAL'] == '1'
  end

  def run_hooks_command(entries)
    command = @pod_names.shift.to_s
    command = 'install' if command.empty?
    case command
    when 'install'
      install_git_hooks(entries)
    else
      raise Pod::Informative, "未知 hooks 命令：#{command}"
    end
  end

  def init_project(action)
    rows = []

    init_project_config
    rows << ['工程配置', '完成', config_path]

    init_project_overlay_file
    rows << ['本地依赖', '完成', overlay_path]

    @pod_names = ['sync']
    run_rules_command
    rows << ['团队规则', '完成', '.gitignore']

    @pod_names = ['init']
    run_skill_command(load_entries)
    rows << ['技能库', '完成', File.join(project_directory, '.podx', 'skills.yml')]

    @pod_names = ['script']
    show_pipeline_map
    rows << ['流程产物', '完成', File.join(project_directory, '.podx', 'pipeline_ci.sh')]

    CocoapodsPodx::AiBootstrap.run(['init'], project_directory: project_directory)
    rows << ['AI 上下文', '完成', project_directory]

    @pod_names = ['install']
    run_hooks_command(load_entries)
    rows << ['Git hooks', '完成', '.githooks/pre-commit / post-merge']

    git_action_print_table("podx #{action} 汇总", %w[项目 状态 说明], rows)
    Pod::UI.puts "podx #{action} [done]"
  end

  def init_project_overlay_file
    previous_pod_names = @pod_names
    previous_disable = @disable
    @pod_names = []
    @disable = false
    create_overlay_file
  ensure
    @pod_names = previous_pod_names
    @disable = previous_disable
  end

  def extract_commit_message_from_arguments!
    filtered_names = []
    index = 0

    while index < @pod_names.length
      token = @pod_names[index]
      if token == '-m' || token == '--message'
        @commit_message ||= @pod_names[index + 1]
        index += 2
      elsif token.start_with?('-m=')
        @commit_message ||= token.sub(/\A-m=/, '')
        index += 1
      elsif token.start_with?('--message=')
        @commit_message ||= token.sub(/\A--message=/, '')
        index += 1
      else
        filtered_names << token
        index += 1
      end
    end

    @pod_names = filtered_names
  end

  def extract_protected_edit_files_from_arguments!
    filtered_names = []
    index = 0

    while index < @pod_names.length
      token = @pod_names[index]
      if token == '-edit' || token == '--edit'
        raise Pod::Informative, "缺少参数值：#{token}" if @pod_names[index + 1].to_s.strip.empty?

        (@protected_edit_files ||= []) << @pod_names[index + 1]
        index += 2
      elsif token.start_with?('-edit=')
        (@protected_edit_files ||= []) << token.sub(/\A-edit=/, '')
        index += 1
      elsif token.start_with?('--edit=')
        (@protected_edit_files ||= []) << token.sub(/\A--edit=/, '')
        index += 1
      else
        filtered_names << token
        index += 1
      end
    end

    @protected_edit_files = Array(@protected_edit_files).map(&:to_s).map(&:strip).reject(&:empty?)
    @pod_names = filtered_names
  end

  def extract_checkout_branch_from_arguments!
    return unless @checkout_mode

    if @pod_names.length == 1 && supported_overlay_names.include?(@pod_names.first.to_s)
      help! "缺少 checkout 目标分支：mgit checkout #{@pod_names.first} BRANCH"
    end

    @checkout_branch = @pod_names.pop.to_s.strip
    help! '请指定 checkout 目标分支，例如：mgit checkout release/5.14.2' if @checkout_branch.empty?
    help! "checkout 目标分支不能使用示例占位符：#{@checkout_branch}，请使用真实分支，例如：mgit checkout release/5.14.2" if placeholder_argument?(@checkout_branch)
  end

  def placeholder_argument?(value)
    text = value.to_s.strip
    return true if text.match?(/\A\[.+\]\z/)
    return true if %w[BRANCH VERSION BUILD NAME N].include?(text)
    return true if text.match?(%r{\Arelease/[xyz](?:\.[xyz])+\z}i)

    false
  end

  def project_directory
    @resolved_project_directory ||= begin
      if @project_directory && !@project_directory.strip.empty?
        File.expand_path(@project_directory)
      else
        find_project_directory(Dir.pwd)
      end
    end
  end

  def ai_project_directory
    @project_directory && !@project_directory.strip.empty? ? File.expand_path(@project_directory) : Dir.pwd
  end

  def configure_runtime!
    return if @runtime_configured

    CocoapodsPodx::Runtime.configure(project_directory: project_directory)
    @runtime_configured = true
  end

  def podfile_path
    configure_runtime!
    File.join(project_directory, 'Podfile')
  end

  def overlay_path
    configure_runtime!
    File.join(project_directory, 'Podfile.overlay')
  end

  def config_path
    preferred = File.join(project_directory, CocoapodsPodx::Runtime::CONFIG_FILE_NAME)
    return preferred if File.exist?(preferred)

    legacy = File.join(project_directory, CocoapodsPodx::Runtime::LEGACY_CONFIG_FILE_NAME)
    return legacy if File.exist?(legacy)

    preferred
  end

  def declared_managed_pod_names
    @declared_managed_pod_names ||= declared_main_entries
      .select { |entry| entry[:type] == :managed_pod && (entry[:group_name].nil? || entry[:group_name] == 'nn_ios') }
      .map { |entry| entry[:name] }
      .uniq
  end

  def declared_biz_group_names
    @declared_biz_group_names ||= declared_main_entries
      .select do |entry|
        entry[:group_name] && entry[:group_name] != 'nn_ios'
      end
      .map { |entry| entry[:group_name] }
      .uniq
  end

  def declared_managed_pod_branches
    @declared_managed_pod_branches ||= begin
      branches = {}
      declared_main_entries.select { |entry| entry[:type] == :managed_pod && (entry[:group_name].nil? || entry[:group_name] == 'nn_ios') }.each do |entry|
        branches[entry[:name]] = entry[:branch] if entry[:branch]
      end
      branches
    end
  end

  def declared_biz_group_branches
    @declared_biz_group_branches ||= begin
      branches = {}
      declared_main_entries.select { |entry| entry[:group_name] && entry[:group_name] != 'nn_ios' }.each do |entry|
        branches[entry[:group_name]] ||= entry[:branch] if entry[:branch]
      end
      branches
    end
  end

  def declared_main_entries
    @declared_main_entries ||= begin
      CocoapodsPodx::Runtime.managed_pod_entries.map do |definition|
        {
          type: :managed_pod,
          name: definition[:name],
          group_name: definition[:group_name],
          branch: definition[:branch],
        }
      end
    end
  end

  def supported_overlay_names
    (declared_managed_pod_names + declared_biz_group_names).uniq
  end

  def validate_pod_names!
    invalid_names = @pod_names.reject { |name| supported_overlay_names.include?(name) }
    return if invalid_names.empty?

    help! "以下组件不在 Podfile.overlay 支持范围内：#{invalid_names.join(', ')}"
  end

  def validate_target_names!
    allowed_names = supported_overlay_names
    allowed_names += ['main'] if git_action_mode?
    invalid_names = @pod_names.reject { |name| allowed_names.include?(name) }
    return if invalid_names.empty?

    help! "以下组件不在 Podfile.overlay 支持范围内：#{invalid_names.join(', ')}"
  end

  def git_action_mode?
    @checkout_mode || @stash_mode || @status_mode || @diff_mode || @log_mode || @add_mode || @pull_mode || @push_mode || @commit_mode
  end

  def find_project_directory(start_dir)
    current_dir = File.expand_path(start_dir)
    original_dir = current_dir

    loop do
      return current_dir if File.exist?(File.join(current_dir, 'Podfile'))

      parent_dir = File.dirname(current_dir)
      break if parent_dir == current_dir

      current_dir = parent_dir
    end

    candidate = Dir.glob(File.join(original_dir, '**', 'Podfile'))
      .reject { |path| path.include?('/Pods/') }
      .min_by { |path| [path.count('/'), path.length] }

    return File.dirname(candidate) if candidate

    File.expand_path(start_dir)
  end

  def init_project_config
    if File.exist?(config_path)
      Pod::UI.puts "podx.config.yml [exists] #{config_path}"
      return
    end

    config = inferred_project_config
    lines = [
      "target_name: #{config[:target_name]}",
      "private_source: #{config[:private_source]}",
      "git_base_url: #{config[:git_base_url]}",
      "publish_work_dir: .mgit-publish",
      'publish_base_branch: develop',
      'publish_pipeline_gate: false',
      '# publish_pipeline_gate_strategy:',
      '#   pgyer: warn',
      '#   testflight: strict',
      '#   appstore: strict',
      '#   framework: warn',
      '# publish_main_repo、publish_update_podfile_branch、publish_version 是工程定制发布动作。',
      '# 通用项目可以不配置；iOS Podfile 工程需要时再显式开启。',
      '# publish_main_repo: nnios',
      '# publish_update_podfile_branch: true',
      'publish_repos:',
      '  - nnios',
      '  - nnbusscom',
      '  - nnimmanager',
      '  - nnbascicommon',
      '  - nnapperance',
      '  - nncategory',
      '  - nnlogmodule',
      '  - nnnetwork',
      '  - nnrealreachability',
      '  - nnyytext',
      '  - nngeneral',
      '  - nnswiftscan',
      '# publish_version:',
      '#   type: ios_xcodeproj',
      "#   branch_pattern: '^release/(\\d+\\.\\d+\\.\\d+)$'",
      '#   project_file: NNIM.xcodeproj/project.pbxproj',
      '#   build_number_strategy: ios_semver',
    ]

    lines << ''
    File.write(config_path, lines.join("\n"))
    Pod::UI.puts "podx.config.yml [created] #{config_path}"
    Pod::UI.puts "请在主 Podfile 中使用 pod 'PodName', :branch => 'develop' 声明需要 overlay 管理的私有组件。"
  end

  def show_plugin_version
    version = Gem.loaded_specs['cocoapods-podx']&.version&.to_s
    version ||= Gem::Specification.find_all_by_name('cocoapods-podx').max_by(&:version)&.version&.to_s
    version ||= local_plugin_version
    Pod::UI.puts "cocoapods-podx #{version}"
  end

  def open_project_resource
    path = if @open_overlay_mode
      overlay_path
    else
      Dir.glob(File.join(project_directory, '*.xcworkspace')).first ||
        Dir.glob(File.join(project_directory, '*.xcodeproj')).first ||
        project_directory
    end

    unless File.exist?(path)
      raise Pod::Informative, "打开失败，文件不存在：#{path}"
    end

    if system('open', path)
      Pod::UI.puts "open [ok] #{path}"
    else
      raise Pod::Informative, "打开失败：#{path}"
    end
  end

  def install_command_shims(gem_home, version = nil)
    pod_bin = `command -v pod`.strip
    return if pod_bin.empty?

    pod_dir = command_shim_dir(pod_bin, gem_home)
    {
      'podx' => podx_shim_content,
      'mgit' => mgit_shim_content
    }.each do |name, content|
      shim = File.join(pod_dir, name)
      File.write(shim, content)
      FileUtils.chmod('+x', shim)
      Pod::UI.puts "#{name} [installed] #{shim}"
    end
    remove_legacy_pox_shim(pod_dir)
  rescue => e
    Pod::UI.puts "podx [warn] #{e.message}"
  end

  def command_shim_dir(pod_bin, gem_home)
    candidates = []
    candidates << File.dirname(pod_bin)
    begin
      candidates << File.dirname(File.realpath(pod_bin))
    rescue
    end
    candidates << File.join(gem_home.to_s, 'bin') unless gem_home.to_s.empty?

    dir = candidates.uniq.find do |path|
      next false unless File.directory?(path)

      File.writable?(path) || %w[podx mgit].all? { |name| File.writable?(File.join(path, name)) }
    end
    raise "无法写入快捷命令目录：#{candidates.compact.uniq.join(', ')}" unless dir

    dir
  end

  def podx_shim_content
    CocoapodsPodx::ShimGenerator.podx
  end

  def mgit_shim_content
    CocoapodsPodx::ShimGenerator.mgit
  end

  def remove_legacy_pox_shim(pod_dir)
    shim = File.join(pod_dir, 'pox')
    return unless File.exist?(shim)

    FileUtils.rm_f(shim)
    Pod::UI.puts "pox [removed] #{shim}"
  rescue => e
    Pod::UI.puts "pox [warn] #{e.message}"
  end

  def local_plugin_version
    gemspec_path = File.expand_path('../../../cocoapods-podx.gemspec', __dir__)
    return 'unknown' unless File.exist?(gemspec_path)

    spec = Gem::Specification.load(gemspec_path)
    spec ? spec.version.to_s : 'unknown'
  rescue
    'unknown'
  end

  def detect_cocoapods_gem_home
    pod_bin = `command -v pod`.strip
    raise Pod::Informative, '未找到 pod 命令' if pod_bin.empty?

    paths = [pod_bin]
    begin
      paths << File.realpath(pod_bin)
    rescue
    end

    paths.uniq.each do |path|
      next unless File.file?(path)

      match = File.read(path).match(/GEM_HOME="([^"]+)"/)
      return match[1] if match
    end

    gem_home = `ruby -e 'require "rubygems"; spec = Gem::Specification.find_all_by_name("cocoapods").max_by(&:version); puts spec&.base_dir'`.strip
    raise Pod::Informative, '无法检测 CocoaPods gem 环境' if gem_home.empty?

    gem_home
  end

  def inferred_project_config
    git_base_url, target_name = infer_git_base_and_target
    private_source = infer_private_source || default_private_source(git_base_url, target_name)

    {
      target_name: target_name || File.basename(project_directory),
      private_source: private_source,
      git_base_url: git_base_url,
    }
  end

  def infer_private_source
    content = File.read(podfile_path)
    match = content.match(/^\s*source\s+['"]([^'"]+)['"]/)
    match && match[1]
  end

  def infer_git_base_and_target
    remote = git_remote_url
    return [nil, File.basename(project_directory)] if remote.nil? || remote.empty?

    normalized = remote.sub(%r{\.git$}, '')
    if normalized =~ %r{\A(https?://[^/]+)/(.+)/[^/]+\z}
      [$1, $2]
    elsif normalized =~ %r{\Agit@([^:]+):(.+)/[^/]+\z}
      ["http://#{$1}", $2]
    else
      [nil, File.basename(project_directory)]
    end
  end

  def git_remote_url
    stdout, status = Open3.capture2e('git', '-C', project_directory, 'remote', 'get-url', 'origin')
    return nil unless status.success?

    stdout.strip
  end

  def default_private_source(git_base_url, target_name)
    return '' if git_base_url.nil? || git_base_url.empty?

    "#{git_base_url}/#{target_name}/nnspec.git"
  end

  def show_branch_info
    branch_names = if @pod_names.empty?
      load_entries.map { |entry| entry[:name] }
    else
      validate_pod_names!
      @pod_names
    end

    if branch_names.empty?
      Pod::UI.puts 'Podfile.overlay 中当前没有本地模式组件。'
      return
    end

    app_branch = main_app_branch
    if app_branch.nil?
      Pod::UI.puts '主工程分支 [unknown]'
    else
      Pod::UI.puts "主工程分支：#{app_branch}"
    end

    branch_names.each do |name|
      print_branch_status(name, app_branch)
    end
  end

  def show_main_config
    names = @pod_names.any? ? @pod_names : supported_overlay_names
    missing = @pod_names.reject { |name| supported_overlay_names.include?(name) }
    help!("These pods are not supported by Podfile.overlay: #{missing.join(', ')}") unless missing.empty?

    names.each do |name|
      branch = declared_branch_for(name) || 'main'
      Pod::UI.puts "#{name} #{branch}"
    end
  end

  def show_overlay_list(entries)
    local_names = entries.map { |entry| entry[:name] }.uniq
    rows = supported_overlay_names.map do |name|
      mode = local_names.include?(name) ? 'local' : 'remote'
      local_branch = mode == 'local' ? (git_branch_for(local_repo_path_for(name)) || 'unknown') : '-'
      [name, mode, local_branch, declared_branch_for(name) || 'main']
    end

    print_box_table('podx list 结果', %w[组件 模式 本地分支 Podfile分支], rows)
    Pod::UI.puts "【podx list 汇总】本地 #{rows.count { |row| row[1] == 'local' }} 个，远端 #{rows.count { |row| row[1] == 'remote' }} 个"
  end

  def print_table(headers, rows)
    widths = headers.each_with_index.map do |header, index|
      ([display_width(header)] + rows.map { |row| display_width(row[index].to_s) }).max
    end
    Pod::UI.puts format_table_row(headers, widths)
    rows.each { |row| Pod::UI.puts format_table_row(row, widths) }
  end

  def print_box_table(title, headers, rows)
    rows = rows.map { |row| row.map { |value| table_cell(value) } }
    headers = headers.map { |value| table_cell(value) }
    widths = headers.each_with_index.map do |header, index|
      ([display_width(header)] + rows.map { |row| display_width(row[index].to_s) }).max
    end

    Pod::UI.puts "【#{title}】"
    separator = "+#{widths.map { |width| '-' * (width + 2) }.join('+')}+"
    Pod::UI.puts separator
    Pod::UI.puts "| #{headers.each_with_index.map { |value, index| pad_display(value, widths[index]) }.join(' | ')} |"
    Pod::UI.puts separator
    rows.each do |row|
      Pod::UI.puts "| #{row.each_with_index.map { |value, index| color_table_value(pad_display(value, widths[index]), value) }.join(' | ')} |"
    end
    Pod::UI.puts separator
  end

  def table_cell(value)
    text = value.to_s.gsub(/\s+/, ' ').strip
    text.empty? ? '-' : text
  end

  def format_table_row(values, widths)
    values.each_with_index.map { |value, index| color_table_value(pad_display(value.to_s, widths[index]), value) }.join('  ')
  end

  def pad_display(value, width)
    value + (' ' * [width - display_width(value), 0].max)
  end

  def display_width(value)
    strip_table_ansi(value).each_char.sum { |char| char.ord > 127 ? 2 : 1 }
  end

  def color_table_value(rendered, raw)
    return rendered unless table_color_enabled?

    case raw.to_s.strip
    when '本地', 'local', '有更新', '跳过'
      table_ansi(rendered, 36)
    when '成功', '正常', '完成', '已更新', '已清理', '已继续', '已放弃'
      table_ansi(rendered, 32)
    when '失败', '缺失'
      table_ansi(rendered, 31)
    when '预览', '未知'
      table_ansi(rendered, 33)
    else
      rendered
    end
  end

  def table_ansi(text, code)
    "\e[#{code}m#{text}\e[0m"
  end

  def table_color_enabled?
    ENV['NO_COLOR'].to_s.empty? && ($stdout.tty? || ENV['COCOAPODS_PODX_COLOR'].to_s == '1')
  end

  def strip_table_ansi(value)
    value.to_s.gsub(/\e\[[0-9;]*m/, '')
  end

  def update_local_repos(entries)
    target_names = overlay_update_target_names(entries)

    if target_names.empty?
      Pod::UI.puts 'Podfile.overlay 中当前没有命中的本地组件仓库可更新。'
      return
    end

    failures = []
    updated_count = 0
    rows = []

    target_names.each do |name|
      begin
        plan = local_repo_update_plan(name, pull: true)
        if @dry_run
          rows << [name, plan[:expected_branch], podx_update_result_label(plan, dry_run: true)]
          updated_count += 1 unless plan[:action] == 'none'
        else
          updated = update_local_repo(name, dry_run: false, quiet: true)
          rows << [name, plan[:expected_branch], podx_update_result_label(plan, updated: updated)]
          updated_count += 1 if updated
        end
      rescue => e
        rows << [name, '-', '失败']
        failures << [name, e.message]
      end
    end

    print_box_table(@dry_run ? 'podx update 预览' : 'podx update 结果', %w[仓库 分支 结果], rows)

    if failures.any?
      message = failures.map { |name, detail| "#{name}: #{detail}" }.join("\n")
      raise Pod::Informative, "以下组件更新失败：\n#{message}"
    end

    Pod::UI.puts @dry_run ? "update [dry-run] #{updated_count}" : "update [done] #{updated_count}"
  end

  def clean_pod_cache_and_installed_pods
    if @pod_names.empty?
      raise Pod::Informative, '请指定要清理的组件，例如：podx clean NNRtc'
    end

    rows = []
    failures = []
    @pod_names.uniq.each do |name|
      cache_result = clean_pod_cache(name)
      pods_result = clean_installed_pod(name)
      rows << [name, cache_result, pods_result]
      failures << "#{name}: #{cache_result}" if cache_result.start_with?('失败')
    end

    print_box_table(@dry_run ? 'podx clean 预览' : 'podx clean 结果', %w[组件 Cache Pods], rows)
    raise Pod::Informative, "以下组件 cache 清理失败：\n#{failures.join("\n")}" if failures.any?

    Pod::UI.puts @dry_run ? "clean [dry-run] #{@pod_names.uniq.size}" : "clean [done] #{@pod_names.uniq.size}"
  end

  def clean_pod_cache(name)
    return '预览清理' if @dry_run

    output, status = Open3.capture2e('pod', 'cache', 'clean', name, '--all')
    return '已清理' if status.success?

    "失败 #{output.to_s.gsub(/\s+/, ' ').strip}"
  end

  def clean_installed_pod(name)
    paths = installed_pod_paths_for(name)
    existing_paths = paths.select { |path| File.exist?(path) }
    return '不存在' if existing_paths.empty?
    return "预览删除 #{existing_paths.map { |path| File.basename(path) }.join(', ')}" if @dry_run

    existing_paths.each { |path| FileUtils.rm_rf(path) }
    "已删除 #{existing_paths.map { |path| File.basename(path) }.join(', ')}"
  end

  def installed_pod_paths_for(name)
    pod_name = name.to_s.strip
    base_name = pod_name.split('/').first
    [pod_name, base_name].uniq.map { |candidate| File.join(project_directory, 'Pods', candidate) }
  end

  def podx_update_result_label(plan, updated: nil, dry_run: false)
    action = plan[:action].to_s
    return '-' if action == 'none'
    return "预览 #{action}" if dry_run
    return '已更新' if updated

    '-'
  end

  def overlay_update_target_names(entries)
    overlay_names = entries.map { |entry| entry[:name] }.uniq
    return overlay_names if @pod_names.empty?

    @pod_names.each_with_object([]) do |name, targets|
      target = overlay_target_name_for(name, overlay_names)
      if target
        targets << target unless targets.include?(target)
      else
        Pod::UI.puts "#{name} [remote] skip local update"
      end
    end
  end

  def overlay_target_name_for(name, overlay_names)
    return name if overlay_names.include?(name)

    definition = CocoapodsPodx::Runtime.managed_pod_definition(name)
    group_name = definition && definition[:group_name]
    return group_name if group_name && overlay_names.include?(group_name)

    nil
  end

  def prepare_local_repos(names)
    return if names.empty?

    failures = []
    updated_count = 0

    names.each do |name|
      begin
        updated_count += 1 if update_local_repo(name, dry_run: false, pull: false)
      rescue => e
        failures << [name, e.message]
      end
    end

    return if failures.empty?

    message = failures.map { |name, detail| "#{name}: #{detail}" }.join("\n")
    raise Pod::Informative, "以下组件本地仓库准备失败，Podfile.overlay 未更新：\n#{message}"
  end

  def preview_prepare_local_repos
    return if @pod_names.empty?

    @pod_names.each do |name|
      print_dry_run_local_repo_plan(name, pull: false)
    rescue => e
      Pod::UI.puts "#{name} [dry-run] failed #{e.message}"
    end
  end

  def doctor_overlay(entries)
    errors = []

    Pod::UI.puts "Podfile [ok] #{podfile_path}"
    doctor_config(errors)

    managed_pod_count = declared_main_entries.size
    if managed_pod_count.zero?
      Pod::UI.puts 'pod [warn] 主 Podfile 中没有内部组件 pod 声明'
    else
      Pod::UI.puts "pod [ok] #{managed_pod_count}"
    end

    if File.exist?(overlay_path)
      Pod::UI.puts "Podfile.overlay [ok] #{entries.size}"
    else
      Pod::UI.puts 'Podfile.overlay [warn] 文件不存在；所有私有组件将走远端'
    end

    invalid_names = entries.map { |entry| entry[:name] }.uniq.reject { |name| supported_overlay_names.include?(name) }
    invalid_names.each do |name|
      errors << "#{name}: 未在主 Podfile 的内部组件 pod 声明中找到"
      Pod::UI.puts "#{name} [error] unsupported"
    end

    app_branch = main_app_branch
    if app_branch
      Pod::UI.puts "主工程分支 [ok] #{app_branch}"
    else
      Pod::UI.puts '主工程分支 [warn] unknown'
    end

    entries.reject { |entry| invalid_names.include?(entry[:name]) }.each do |entry|
      doctor_local_repo(entry[:name], app_branch, errors)
    end

    if errors.empty?
      Pod::UI.puts 'doctor [ok]'
    else
      raise Pod::Informative, "doctor [failed] #{errors.size}\n#{errors.join("\n")}"
    end
  end

  def doctor_config(errors)
    preferred_config_path = File.join(project_directory, CocoapodsPodx::Runtime::CONFIG_FILE_NAME)
    legacy_config_path = File.join(project_directory, CocoapodsPodx::Runtime::LEGACY_CONFIG_FILE_NAME)
    if File.exist?(preferred_config_path) && File.exist?(legacy_config_path)
      errors << '同时存在 podx.config.yml 和 Podfile.overlay.config.yml，请只保留 podx.config.yml'
      Pod::UI.puts 'podx.config.yml [warn] legacy config also exists'
    end

    unless File.exist?(config_path)
      errors << "缺少配置文件：#{config_path}"
      Pod::UI.puts "podx.config.yml [error] missing"
      return
    end

    config = YAML.safe_load(File.read(config_path), permitted_classes: [], permitted_symbols: [], aliases: false) || {}
    missing_keys = %w[target_name private_source git_base_url].reject do |key|
      value = config[key]
      !value.nil? && !value.to_s.strip.empty?
    end

    if missing_keys.empty?
      Pod::UI.puts "podx.config.yml [ok] #{config_path}"
    else
      errors << "配置文件缺少字段：#{missing_keys.join(', ')}"
      Pod::UI.puts "podx.config.yml [error] missing #{missing_keys.join(', ')}"
    end
  rescue => e
    errors << "配置文件读取失败：#{e.message}"
    Pod::UI.puts "podx.config.yml [error] #{e.message}"
  end

  def doctor_local_repo(name, app_branch, errors)
    repo_path = local_repo_path_for(name)
    unless File.directory?(repo_path)
      errors << "#{name}: 本地仓库不存在 #{repo_path}"
      Pod::UI.puts "#{name} [error] missing #{repo_path}"
      return
    end

    branch = git_branch_for(repo_path)
    if branch.nil?
      errors << "#{name}: 无法获取当前分支"
      Pod::UI.puts "#{name} [error] branch unknown"
      return
    end

    expected_branch = app_branch || declared_branch_for(name) || 'main'
    if branch == expected_branch
      Pod::UI.puts "#{name} [ok] #{branch}"
    else
      errors << "#{name}: 当前分支 #{branch}，期望分支 #{expected_branch}"
      Pod::UI.puts "#{name} [error] #{branch} -> #{expected_branch}"
    end

    Pod::UI.puts "#{name} [warn] dirty" if git_dirty?(repo_path)
  end

  def update_local_repo(name, dry_run: false, pull: true, expected_branch: nil, quiet: false)
    repo_path = local_repo_path_for(name)
    app_branch = main_app_branch
    declared_branch = declared_branch_for(name)
    expected_branch = expected_branch || app_branch || declared_branch || 'main'
    return clone_local_repo(name, repo_path, expected_branch, dry_run: dry_run, quiet: quiet) unless File.directory?(repo_path)
    return reclone_invalid_local_repo(name, repo_path, expected_branch, dry_run: dry_run, quiet: quiet) unless git_work_tree?(repo_path)

    current_branch = git_branch_for(repo_path)
    return false if current_branch == expected_branch && !pull

    unless dry_run
      should_change_branch = current_branch != expected_branch
      if should_change_branch
        raise "本地仓库存在未提交修改：#{repo_path}" if git_dirty?(repo_path)
        run_git!(repo_path, 'fetch', 'origin')
      elsif pull
        run_git!(repo_path, 'fetch', 'origin')
        return false unless git_remote_has_updates?(repo_path, expected_branch)

        raise "本地仓库存在未提交修改：#{repo_path}" if git_dirty?(repo_path)
      end
    end

    if current_branch.nil?
      checkout_message = "[checkout] detached -> #{expected_branch}"
      if dry_run
        Pod::UI.puts "#{name} [dry-run] #{checkout_message}" unless quiet
        return true
      end

      checkout_branch!(repo_path, expected_branch)
      run_git!(repo_path, 'pull', '--ff-only', 'origin', expected_branch)
      Pod::UI.puts [name, '[updated]', checkout_message].join(' ') unless quiet
      return true
    end

    if current_branch == expected_branch
      run_git!(repo_path, 'pull', '--ff-only', 'origin', expected_branch) unless dry_run
      return false
    end

    checkout_message = "[checkout] #{current_branch} -> #{expected_branch}"
    if dry_run
      Pod::UI.puts "#{name} [dry-run] #{checkout_message}" unless quiet
      return true
    end

    checkout_branch!(repo_path, expected_branch)
    run_git!(repo_path, 'pull', '--ff-only', 'origin', expected_branch)

    status_parts = [name, '[updated]', checkout_message]
    Pod::UI.puts status_parts.join(' ') unless quiet
    true
  end

  def local_repo_update_plan(name, pull:)
    repo_path = local_repo_path_for(name)
    app_branch = main_app_branch
    declared_branch = declared_branch_for(name)
    expected_branch = app_branch || declared_branch || 'main'

    return { current_branch: '-', expected_branch: expected_branch, action: 'clone' } unless File.directory?(repo_path)
    return { current_branch: '-', expected_branch: expected_branch, action: 'reclone' } unless git_work_tree?(repo_path)

    current_branch = git_branch_for(repo_path)
    return { current_branch: 'detached', expected_branch: expected_branch, action: 'checkout' } if current_branch.nil?
    return { current_branch: current_branch, expected_branch: expected_branch, action: "checkout #{current_branch} -> #{expected_branch}" } if current_branch != expected_branch
    return { current_branch: current_branch, expected_branch: expected_branch, action: pull ? 'pull' : 'none' }
  end

  def print_dry_run_local_repo_plan(name, pull:)
    repo_path = local_repo_path_for(name)
    remote_url = CocoapodsPodx::Runtime.remote_repo_url_for(name)
    app_branch = main_app_branch
    declared_branch = declared_branch_for(name)
    expected_branch = app_branch || declared_branch || 'main'

    Pod::UI.puts "#{name} [dry-run] repo #{repo_path}"
    Pod::UI.puts "#{name} [dry-run] remote #{remote_url}"
    Pod::UI.puts "#{name} [dry-run] branch target #{expected_branch}"

    unless File.directory?(repo_path)
      Pod::UI.puts "#{name} [dry-run] action clone #{expected_branch}"
      return true
    end

    unless git_work_tree?(repo_path)
      backup_path = "#{repo_path}.invalid-YYYYmmddHHMMSS"
      Pod::UI.puts "#{name} [dry-run] action backup #{backup_path}"
      Pod::UI.puts "#{name} [dry-run] action reclone #{expected_branch}"
      return true
    end

    current_branch = git_branch_for(repo_path)
    dirty = git_dirty?(repo_path)
    Pod::UI.puts "#{name} [dry-run] branch current #{current_branch || 'detached'}"
    Pod::UI.puts "#{name} [dry-run] worktree dirty" if dirty

    if current_branch.nil?
      Pod::UI.puts "#{name} [dry-run] action checkout detached -> #{expected_branch}"
      Pod::UI.puts "#{name} [dry-run] action pull origin/#{expected_branch}" if pull
      return true
    end

    if current_branch != expected_branch
      Pod::UI.puts "#{name} [dry-run] action checkout #{current_branch} -> #{expected_branch}"
      Pod::UI.puts "#{name} [dry-run] action pull origin/#{expected_branch}" if pull
      return true
    end

    if pull
      Pod::UI.puts "#{name} [dry-run] action pull origin/#{expected_branch}"
      true
    else
      Pod::UI.puts "#{name} [dry-run] action none"
      false
    end
  end

  def clone_local_repo(name, repo_path, expected_branch, dry_run: false, quiet: false)
    remote_url = CocoapodsPodx::Runtime.remote_repo_url_for(name)

    if dry_run
      Pod::UI.puts "#{name} [dry-run] [clone] #{remote_url} -> #{repo_path} #{expected_branch}" unless quiet
      return true
    end

    FileUtils.mkdir_p(File.dirname(repo_path))
    run_git!(File.dirname(repo_path), 'clone', '--branch', expected_branch, remote_url, repo_path)
    Pod::UI.puts "#{name} [updated] [clone] #{expected_branch}" unless quiet
    true
  end

  def reclone_invalid_local_repo(name, repo_path, expected_branch, dry_run: false, quiet: false)
    backup_path = "#{repo_path}.invalid-#{Time.now.strftime('%Y%m%d%H%M%S')}"

    if dry_run
      remote_url = CocoapodsPodx::Runtime.remote_repo_url_for(name)
      unless quiet
        Pod::UI.puts "#{name} [dry-run] [reclone] #{repo_path} -> #{backup_path}"
        Pod::UI.puts "#{name} [dry-run] [clone] #{remote_url} -> #{repo_path} #{expected_branch}"
      end
      return true
    end

    FileUtils.mv(repo_path, backup_path)
    clone_local_repo(name, repo_path, expected_branch, dry_run: false, quiet: quiet)
    Pod::UI.puts "#{name} [backup] #{backup_path}" unless quiet
    true
  end

  def local_repo_path_for(name)
    repo_dir = CocoapodsPodx::Runtime.local_repo_folder_name_for(name)
    File.expand_path(File.join(project_directory, 'Development Pods', repo_dir))
  end

  def git_branch_for(path)
    return nil unless File.directory?(path)

    stdout, status = Open3.capture2('git', '-C', path, 'branch', '--show-current')
    return nil unless status.success?

    branch = stdout.strip
    branch.empty? ? nil : branch
  end

  def git_work_tree?(path)
    stdout, status = Open3.capture2('git', '-C', path, 'rev-parse', '--is-inside-work-tree')
    status.success? && stdout.strip == 'true'
  end

  def git_dirty?(path)
    stdout, status = Open3.capture2('git', '-C', path, 'status', '--porcelain')
    return true unless status.success?

    !stdout.strip.empty?
  end

  def git_status_lines(path)
    stdout, status = Open3.capture2('git', '-C', path, 'status', '--short')
    return ["status failed: #{stdout.strip}"] unless status.success?

    stdout.lines.map(&:chomp).reject(&:empty?)
  end

  def git_diff_lines(path)
    stdout, status = Open3.capture2('git', '-C', path, 'diff')
    return ["diff failed: #{stdout.strip}"] unless status.success?

    stdout.lines.map(&:chomp)
  end

  def git_log_lines(path, limit)
    stdout, status = Open3.capture2('git', '-C', path, 'log', "--max-count=#{limit}", '--pretty=format:%h %ad %s', '--date=short')
    return ["log failed: #{stdout.strip}"] unless status.success?

    stdout.lines.map(&:chomp).reject(&:empty?)
  end

  def run_git!(path, *args)
    stdout, status = Open3.capture2e('git', '-C', path, *args)
    return stdout if status.success?

    raise stdout.strip.empty? ? "git #{args.join(' ')} 执行失败" : stdout.strip
  end

  def checkout_branch!(path, branch)
    if git_local_branch_exists?(path, branch)
      run_git!(path, 'checkout', branch)
    elsif git_remote_branch_exists?(path, branch)
      run_git!(path, 'checkout', '-b', branch, '--track', "origin/#{branch}")
    else
      raise "远端不存在分支 #{branch}"
    end
  end

  def git_local_branch_exists?(path, branch)
    _, status = Open3.capture2('git', '-C', path, 'show-ref', '--verify', '--quiet', "refs/heads/#{branch}")
    status.success?
  end

  def git_remote_branch_exists?(path, branch)
    stdout, status = Open3.capture2('git', '-C', path, 'ls-remote', '--heads', 'origin', branch)
    status.success? && !stdout.strip.empty?
  end

  def git_remote_has_updates?(path, branch)
    stdout, status = Open3.capture2('git', '-C', path, 'rev-list', '--count', "HEAD..origin/#{branch}")
    return true unless status.success?

    stdout.to_i.positive?
  end

  def declared_branch_for(name)
    declared_managed_pod_branches[name] || declared_biz_group_branches[name]
  end

  def main_app_branch
    git_branch_for(project_directory) || git_branch_for(Dir.pwd)
  end

  def print_branch_status(name, app_branch)
    Pod::UI.puts format_branch_status(name, branch_status_for(name, app_branch))
  end

  def branch_status_for(name, app_branch)
    repo_path = local_repo_path_for(name)
    return { ok: false, tag: 'missing', branch: nil, message: "#{name}: 本地仓库不存在" } unless File.directory?(repo_path)

    branch = git_branch_for(repo_path)
    return { ok: false, tag: 'unknown', branch: nil, message: "#{name}: 无法获取当前分支" } if branch.nil?
    return { ok: false, tag: 'unknown', branch: branch, message: "#{name}: 无法获取主工程当前分支" } if app_branch.nil?

    same_as_app = branch == app_branch
    {
      ok: same_as_app,
      tag: same_as_app ? 'ok' : 'no',
      branch: branch,
      app_branch: app_branch,
      message: same_as_app ? nil : "#{name}: 当前分支 #{branch}，主工程分支 #{app_branch}"
    }
  end

  def format_branch_status(name, status)
    case status[:tag]
    when 'ok'
      "#{name} [ok] #{status[:branch]}"
    when 'no'
      "#{name} [no] #{status[:branch]} -> #{status[:app_branch]}"
    when 'missing'
      "#{name} [missing]"
    else
      branch = status[:branch]
      branch ? "#{name} [unknown] #{branch}" : "#{name} [unknown]"
    end
  end

  def extract_option(source, option_name)
    match = source.match(/#{Regexp.escape(option_name)}:\s*['"]([^'"]+)['"]/)
    match && match[1]
  end
end
