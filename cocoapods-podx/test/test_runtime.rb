require 'fileutils'
require 'tmpdir'
require 'minitest/autorun'

module Pod
  class Informative < StandardError; end
end unless defined?(Pod::Informative)

module Pod
  module UI
    def self.puts(*); end
  end
end unless defined?(Pod::UI)

require_relative '../lib/cocoapods_podx/commands/git_actions'
require_relative '../lib/cocoapods_podx/commands/jenkins_publish'
require_relative '../lib/cocoapods_podx/commands/mgit_publish'
require_relative '../lib/cocoapods_podx/commands/overlay_file'
require_relative '../lib/cocoapods_podx/ai_bootstrap'
require_relative '../lib/cocoapods_podx/mgit_standalone'
require_relative '../lib/cocoapods_podx/publish_only'
require_relative '../lib/cocoapods_podx/runtime'
require_relative '../lib/cocoapods_podx/shim_generator'

class CocoapodsPodxRuntimeTest < Minitest::Test
  def setup
    @project_dir = Dir.mktmpdir('cocoapods-podx-test')
    File.write(File.join(@project_dir, 'podx.config.yml'), <<~YAML)
      target_name: nn_ios
      private_source: http://git.example.com/nn_ios/specs.git
      git_base_url: http://git.example.com
      publish_work_dir: .mgit-publish
      publish_base_branch: develop
      publish_main_repo: nnios
      publish_update_podfile_branch: true
      publish_repos:
        - nnios
        - nnbusscom
      publish_version:
        type: ios_xcodeproj
        branch_pattern: '^release/(\\d+\\.\\d+\\.\\d+)$'
        project_file: NNIM.xcodeproj/project.pbxproj
        build_number_strategy: ios_semver
    YAML
    File.write(File.join(@project_dir, 'Podfile'), <<~RUBY)
      source 'http://git.example.com/nn_ios/specs.git'
      pod 'NNApperance', :branch => 'develop'
      pod 'NNLibrary', :branch => 'develop', :remote_name => 'NNYYText', :local_name => 'NNLibrary'
      pod 'NNLogin', :branch => 'develop', :group_name => 'NNBussCom'
      pod 'Alamofire'
      pod 'GitOnlyPod', :git => 'http://git.example.com/open/GitOnlyPod.git', :branch => 'main'
      pod 'DebugOnlyPod', '1.0.0', :configurations => ['Debug']
    RUBY
    CocoapodsPodx::Runtime.configure(project_directory: @project_dir)
  end

  def teardown
    FileUtils.remove_entry(@project_dir) if @project_dir && File.directory?(@project_dir)
  end

  def test_internal_pod_definitions_are_managed_and_normal_pod_definitions_are_not
    assert CocoapodsPodx::Runtime.managed_pod?('NNApperance')
    refute CocoapodsPodx::Runtime.managed_pod?('Alamofire')
    refute CocoapodsPodx::Runtime.managed_pod?('GitOnlyPod')
    refute CocoapodsPodx::Runtime.managed_pod?('DebugOnlyPod')

    definition = CocoapodsPodx::Runtime.managed_pod_definition('NNLibrary')
    assert_equal 'develop', definition[:branch]
    assert_equal 'NNYYText', definition[:remote_name]
    assert_equal 'NNLibrary', definition[:local_name]
  end

  def test_group_names_are_supported_overlay_names
    assert_equal(
      ['NNApperance', 'NNLibrary', 'NNBussCom'],
      CocoapodsPodx::Runtime.podfile_supported_overlay_names
    )
  end

  def test_pod_overlay_accepts_pod_entries
    overlay = CocoapodsPodx::Runtime::PodOverlay.new
    overlay.instance_eval(<<~RUBY)
      pod 'NNBussCom'
      pod 'NNBasciCommon'
    RUBY

    assert_equal({}, overlay.config_for('NNBussCom'))
    assert_equal({}, overlay.config_for('NNBasciCommon'))
  end

  def test_remote_options_use_overrides_from_internal_pod
    options = CocoapodsPodx::Runtime.pod_options_for(name: 'NNLibrary')

    assert_equal 'http://git.example.com/nn_ios/nnyytext.git', options[:git]
    assert_equal 'develop', options[:branch]
    assert_equal false, options[:inhibit_warnings]
  end

  def test_remote_repo_url_for_overlay_entries
    assert_equal(
      'http://git.example.com/nn_ios/nnyytext.git',
      CocoapodsPodx::Runtime.remote_repo_url_for('NNLibrary')
    )
    assert_equal(
      'http://git.example.com/nn_ios/nnbusscom.git',
      CocoapodsPodx::Runtime.remote_repo_url_for('NNBussCom')
    )
  end

  def test_project_config_exposes_publish_settings
    config = CocoapodsPodx::Runtime.config

    assert_equal '.mgit-publish', config[:publish_work_dir]
    assert_equal 'develop', config[:publish_base_branch]
    assert_equal 'nnios', config[:publish_main_repo]
    assert_equal true, config[:publish_update_podfile_branch]
    assert_equal ['nnios', 'nnbusscom'], config[:publish_repos]
    assert_equal 'ios_xcodeproj', config[:publish_version][:type]
    assert_equal '^release/(\\d+\\.\\d+\\.\\d+)$', config[:publish_version][:branch_pattern]
    assert_equal 'ios_semver', config[:publish_version][:build_number_strategy]
  end

  def test_runtime_prefers_podx_config
    assert_equal File.join(@project_dir, 'podx.config.yml'), CocoapodsPodx::Runtime.send(:config_path)
  end

  def test_runtime_falls_back_to_legacy_overlay_config
    legacy_dir = Dir.mktmpdir('cocoapods-podx-legacy-config')
    File.write(File.join(legacy_dir, 'Podfile.overlay.config.yml'), <<~YAML)
      target_name: legacy
      private_source: http://git.example.com/legacy/specs.git
      git_base_url: http://git.example.com
    YAML

    CocoapodsPodx::Runtime.configure(project_directory: legacy_dir)

    assert_equal File.join(legacy_dir, 'Podfile.overlay.config.yml'), CocoapodsPodx::Runtime.send(:config_path)
    assert_equal 'legacy', CocoapodsPodx::Runtime.config[:target_name]
  ensure
    CocoapodsPodx::Runtime.configure(project_directory: @project_dir) if @project_dir
    FileUtils.rm_rf(legacy_dir) if legacy_dir
  end

  def test_shim_generator_reads_bin_templates
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'pod 扩展命令'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx upgrade [VERSION]'
    refute_includes CocoapodsPodx::ShimGenerator.podx, 'podx uninstall                 '
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx list'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx ai init'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx publish log [BUILD]'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx publish history [N]'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx publish doctor [BUILD]'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx publish fix [BUILD]'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'cocoapods_podx/publish_only'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'detect_cocoapods_gem_home'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'detect_cocoapods_ruby'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'detect_podx_lib_path'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'pod_available'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'pod --version'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'latest_podx_version_from_nexus'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'upgrade_cocoapods_podx'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'cocoapods-podx $current_version 已是最新版本，无需更新'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'GEM_HOME="$gem_home"'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'RUBYLIB="$podx_lib'
    refute_includes CocoapodsPodx::ShimGenerator.podx, 'pod overlay --jenkins-fix'
    refute_includes CocoapodsPodx::ShimGenerator.podx, 'overlay --jenkins-fix'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'COCOAPODS_PODX_INTERNAL=1'
    refute_includes CocoapodsPodx::ShimGenerator.podx, 'branch|list)'
    refute_includes CocoapodsPodx::ShimGenerator.podx, '请使用 mgit branch'
    assert_includes CocoapodsPodx::ShimGenerator.mgit, 'mgit publish'
    assert_includes CocoapodsPodx::ShimGenerator.mgit, 'mgit_standalone'
    assert_includes CocoapodsPodx::ShimGenerator.mgit, 'detect_cocoapods_gem_home'
    assert_includes CocoapodsPodx::ShimGenerator.mgit, 'detect_podx_lib_path'
    assert_includes CocoapodsPodx::ShimGenerator.mgit, 'RUBYLIB="$podx_lib'
    refute_includes CocoapodsPodx::ShimGenerator.mgit, 'pod overlay'
    refute_includes CocoapodsPodx::ShimGenerator.mgit, 'COCOAPODS_PODX_INTERNAL=1'
  end

  def test_ai_bootstrap_generates_claude_and_graph_files_without_codex_prompts
    ai_dir = Dir.mktmpdir('cocoapods-podx-ai')

    Dir.chdir(ai_dir) do
      CocoapodsPodx::AiBootstrap.run(['init'], project_directory: ai_dir)
    end

    refute File.exist?(File.join(ai_dir, 'AGENTS.md'))
    refute File.exist?(File.join(ai_dir, 'prompts'))
    assert File.exist?(File.join(ai_dir, 'CLAUDE.md'))
    assert File.exist?(File.join(ai_dir, '.claude', 'README.md'))
    assert File.exist?(File.join(ai_dir, '.claude', 'commands', 'feature.md'))
    assert File.exist?(File.join(ai_dir, '.claude', 'commands', 'podx.md'))
    assert File.exist?(File.join(ai_dir, '.claude', 'commands', 'requirement.md'))
    assert File.exist?(File.join(ai_dir, '.claude', 'commands', 'test.md'))
    assert File.exist?(File.join(ai_dir, '.claude', 'commands', 'release.md'))
    assert File.exist?(File.join(ai_dir, '.claude', 'commands', 'evolve.md'))
    assert File.exist?(File.join(ai_dir, '.claude', 'rules', 'project.md'))
    assert File.exist?(File.join(ai_dir, '.claude', 'rules', 'codegraph.md'))
    assert File.exist?(File.join(ai_dir, '.claude', 'rules', 'ios-project.md'))
    assert File.exist?(File.join(ai_dir, '.claude', 'rules', 'workflow.md'))
    assert File.exist?(File.join(ai_dir, '.claude', 'skills', 'feature.md'))
    assert File.exist?(File.join(ai_dir, '.claude', 'skills', 'ai-evolution.md'))
    assert File.exist?(File.join(ai_dir, '.claude', 'agents', 'ios-engineer.md'))
    assert File.exist?(File.join(ai_dir, '.claude', 'agents', 'ai-platform-maintainer.md'))
    assert File.exist?(File.join(ai_dir, '.claude', 'memory', 'README.md'))
    assert File.exist?(File.join(ai_dir, '.claude', 'memory', 'project-memory-template.md'))
    assert File.exist?(File.join(ai_dir, '.claude', 'mcps', 'README.md'))
    assert File.exist?(File.join(ai_dir, '.claude', 'mcps', 'claude-mcp.example.json'))
    assert File.exist?(File.join(ai_dir, '.claude', 'mcps', 'codex-mcp.example.toml'))
    assert File.executable?(File.join(ai_dir, '.claude', 'mcps', 'codegraph.sh'))
    assert File.executable?(File.join(ai_dir, '.claude', 'mcps', 'codegraph-mcp.sh'))
    assert File.executable?(File.join(ai_dir, '.claude', 'mcps', 'hermes-mcp.sh'))
    assert File.executable?(File.join(ai_dir, '.claude', 'mcps', 'setup-hermes-mcp.sh'))
    assert File.executable?(File.join(ai_dir, '.claude', 'mcps', 'init-codegraph.sh'))
    assert File.executable?(File.join(ai_dir, '.claude', 'mcps', 'update-codegraph.sh'))
    refute File.exist?(File.join(ai_dir, '.claude', 'mcp'))
    refute File.exist?(File.join(ai_dir, 'tools', 'podx-ai'))
    assert_includes File.read(File.join(ai_dir, '.gitignore')), '# AI / MCP local runtime state'
    assert_includes File.read(File.join(ai_dir, '.gitignore')), '.claude/memory/MEMORY.md'
    assert_includes File.read(File.join(ai_dir, '.gitignore')), '.claude/mcps/.env'
    assert_includes File.read(File.join(ai_dir, '.claude', 'mcps', 'codex-mcp.example.toml')), 'code-review-graph'
    assert_includes File.read(File.join(ai_dir, '.claude', 'mcps', 'claude-mcp.example.json')), 'code-review-graph'
    assert_includes File.read(File.join(ai_dir, '.claude', 'mcps', 'README.md')), 'Hermes'
    assert_includes File.read(File.join(ai_dir, '.claude', 'memory', 'README.md')), 'Hermes Memory'
  ensure
    FileUtils.rm_rf(ai_dir) if ai_dir
  end

  def test_jenkins_failure_lines_prioritize_cocoapods_invalid_podfile
    parser = Object.new
    parser.extend(CocoapodsPodx::Commands::JenkinsPublish)

    lines = <<~LOG.lines.map(&:strip).reject(&:empty?)
      [!] Invalid `Podfile` file: 未找到 overlay 配置文件：/Users/a1/.jenkins/workspace/nn/Podfile.overlay.config.yml.
       #  from /Users/a1/.jenkins/workspace/nn/Podfile:7
       #  -------------------------------------------
       >  source private_source
       #  #source mirror_source
       #  -------------------------------------------
      [ERROR] CocoaPods依赖安装失败
      [ERROR]   1. 检查 git.leigod.top 网络连通性
      Build step 'Execute shell' marked build as failure
      Finished: FAILURE
    LOG

    failure_lines = parser.jenkins_primary_failure_lines(lines)

    assert_equal '[!] Invalid `Podfile` file: 未找到 overlay 配置文件：/Users/a1/.jenkins/workspace/nn/Podfile.overlay.config.yml.', failure_lines.first
    assert_includes failure_lines, '>  source private_source'
    refute_includes failure_lines, "Build step 'Execute shell' marked build as failure"
  end

  def test_show_jenkins_build_log_reads_console_text_with_line_limit
    logger = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      attr_reader :requested_url

      def initialize(project_dir)
        @project_directory = project_dir
        @pod_names = []
        @jenkins_log_lines = '2'
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def selected_jenkins_job_url
        'http://jenkins.example.com/job/nn/'
      end

      def request_jenkins(uri, _request, open_timeout: nil, read_timeout: nil)
        @requested_url = uri.to_s
        response = Net::HTTPOK.new('1.1', '200', 'OK')
        response.instance_variable_set(:@read, true)
        response.instance_variable_set(:@body, "line1\nline2\nline3\n")
        response
      end

      def open_jenkins_log_file(path)
        @opened_log_file = path
      end
    end.new(@project_dir)

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      logger.show_jenkins_build_log
    end

    assert_equal 'http://jenkins.example.com/job/nn/lastBuild/consoleText', logger.requested_url
    assert_includes output, '【Jenkins日志】http://jenkins.example.com/job/nn/lastBuild/consoleText'
    assert_includes output, '【日志文件】'
    refute_includes output, 'line1'
    refute_includes output, 'line2'
    refute_includes output, 'line3'
    log_file = logger.instance_variable_get(:@opened_log_file)
    assert File.exist?(log_file)
    refute_includes File.read(log_file), 'line1'
    assert_includes File.read(log_file), 'line2'
    assert_includes File.read(log_file), 'line3'
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_show_jenkins_build_log_reports_connection_error_without_crash_template
    logger = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      def initialize(project_dir)
        @project_directory = project_dir
        @pod_names = []
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def selected_jenkins_job_url
        'http://10.1.3.177:8080/job/nn/'
      end

      def request_jenkins(_uri, _request, open_timeout: nil, read_timeout: nil)
        raise Errno::EPERM, 'Operation not permitted - connect(2) for "10.1.3.177" port 8080'
      end
    end.new(@project_dir)

    error = assert_raises(Pod::Informative) do
      logger.show_jenkins_build_log
    end

    assert_includes error.message, '无法连接 Jenkins'
    assert_includes error.message, '10.1.3.177'
    assert_includes error.message, '普通终端执行或授权网络访问'
  end

  def test_show_jenkins_build_log_falls_back_to_backup_jenkins_url
    logger = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      attr_reader :requested_urls

      def initialize(project_dir)
        @project_directory = project_dir
        @pod_names = ['1274']
        @requested_urls = []
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def jenkins_job_urls
        [
          'http://10.1.3.177:8080/job/nn/',
          'http://10.1.107.211:8080/job/nn/'
        ]
      end

      def request_jenkins(uri, _request, open_timeout: nil, read_timeout: nil)
        @requested_urls << uri.to_s
        raise Net::OpenTimeout, 'execution expired' if uri.to_s.include?('10.1.3.177')

        Net::HTTPSuccess.new('1.1', '200', 'OK').tap do |response|
          response.instance_variable_set(:@read, true)
          response.instance_variable_set(:@body, "line1\nline2\n")
        end
      end

      def open_jenkins_log_file(path)
        @opened_path = path
      end
    end.new(@project_dir)

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      logger.show_jenkins_build_log
    end

    assert_equal 2, logger.requested_urls.length
    assert_includes logger.requested_urls[0], '10.1.3.177'
    assert_includes logger.requested_urls[1], '10.1.107.211'
    assert_includes output, '切换备用：http://10.1.107.211:8080/job/nn/1274/'
    assert_includes output, '【Jenkins日志】http://10.1.107.211:8080/job/nn/1274/consoleText'
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_show_jenkins_build_history_prints_recent_build_table
    history = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      attr_reader :requested_url

      def initialize(project_dir)
        @project_directory = project_dir
        @pod_names = []
        @jenkins_history_limit = '2'
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def jenkins_job_urls
        ['http://jenkins.example.com/job/nn/']
      end

      def jenkins_json(uri)
        @requested_url = uri.to_s
        {
          'builds' => [
            {
              'number' => 1274,
              'result' => 'FAILURE',
              'duration' => 123_000,
              'building' => false,
              'actions' => [
                {
                  'parameters' => [
                    { 'name' => 'branch', 'value' => 'origin/develop' },
                    { 'name' => 'DEPLOY_TARGET', 'value' => 'Pgyer,' },
                    { 'name' => 'PODX_TRIGGER_SOURCE', 'value' => 'podx publish' }
                  ]
                },
                {
                  'causes' => [
                    { 'shortDescription' => 'Started by user anonymous', 'userName' => 'anonymous' }
                  ]
                }
              ],
              'changeSet' => {
                'items' => [
                  { 'commitId' => 'abcdef1234567890', 'msg' => 'fix: build failure' }
                ]
              }
            },
            {
              'number' => 1275,
              'result' => nil,
              'duration' => 0,
              'building' => true,
              'actions' => [
                {
                  'parameters' => [
                    { 'name' => 'BRANCH', 'value' => 'origin/release/5.14.2' },
                    { 'name' => 'DEPLOY_TARGET', 'value' => 'TestFlight,' },
                    { 'name' => 'VERIFICATION_PASSWORD', 'value' => '***,' }
                  ]
                },
                {
                  'causes' => [
                    { 'shortDescription' => 'Started by user admin', 'userName' => 'admin' }
                  ]
                }
              ],
              'changeSet' => { 'items' => [] }
            }
          ]
        }
      end
    end.new(@project_dir)

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      history.show_jenkins_build_history
    end

    assert_includes history.requested_url, 'api/json?tree=builds'
    assert_includes history.requested_url, '{0,2}'
    assert_includes output, '【Jenkins任务】http://jenkins.example.com/job/nn/'
    assert_includes output, '【最近构建】2'
    assert_includes output, '| 构建号'
    assert_includes output, '#1274'
    assert_includes output, 'develop'
    refute_includes output, 'origin/develop'
    assert_includes output, '蒲公英'
    assert_includes output, 'podx publish'
    assert_includes output, 'FAILURE'
    assert_includes output, '2m3s'
    assert_includes output, 'abcdef'
    assert_includes output, 'fix: build failure'
    assert_includes output, '#1275'
    assert_includes output, 'release/5.14.2'
    refute_includes output, 'origin/release/5.14.2'
    assert_includes output, 'TestFlight'
    assert_includes output, 'podx publish'
    assert_includes output, 'BUILDING'
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_show_jenkins_build_history_falls_back_to_backup_jenkins_url
    history = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      attr_reader :requested_urls

      def initialize(project_dir)
        @project_directory = project_dir
        @pod_names = []
        @jenkins_history_limit = '3'
        @requested_urls = []
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def jenkins_job_urls
        [
          'http://10.1.3.177:8080/job/nn/',
          'http://10.1.107.211:8080/job/nn/'
        ]
      end

      def jenkins_json(uri)
        @requested_urls << uri.to_s
        raise Net::OpenTimeout, 'execution expired' if uri.to_s.include?('10.1.3.177')

        {
          'builds' => [
            {
              'number' => 1282,
              'result' => 'SUCCESS',
              'duration' => 30_000,
              'building' => false,
              'actions' => [
                {
                  'parameters' => [
                    { 'name' => 'branch', 'value' => 'origin/develop' },
                    { 'name' => 'DEPLOY_TARGET', 'value' => 'Pgyer,' },
                    { 'name' => 'PODX_TRIGGER_SOURCE', 'value' => 'podx publish' }
                  ]
                }
              ],
              'changeSet' => {
                'items' => [
                  { 'commitId' => 'abcdef1234567890', 'msg' => 'update: publish' }
                ]
              }
            }
          ]
        }
      end
    end.new(@project_dir)

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      history.show_jenkins_build_history
    end

    assert_equal 2, history.requested_urls.length
    assert_includes history.requested_urls[0], '10.1.3.177'
    assert_includes history.requested_urls[1], '10.1.107.211'
    assert_includes output, '切换备用：http://10.1.107.211:8080/job/nn/'
    assert_includes output, '【Jenkins任务】http://10.1.107.211:8080/job/nn/'
    assert_includes output, '#1282'
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_jenkins_history_source_keeps_named_user_as_manual
    helper = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish
    end.new

    source = helper.jenkins_history_source(
      {
        'branch' => 'origin/develop',
        'DEPLOY_TARGET' => 'Pgyer,',
        'VERIFICATION_PASSWORD' => ','
      },
      [
        { description: 'Started by user admin', user_name: 'admin', user_id: 'admin' }
      ]
    )

    assert_equal 'Jenkins手动', source
  end

  def test_doctor_jenkins_build_reports_podfile_configuration_failure
    doctor = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      def initialize(project_dir)
        @project_directory = project_dir
        @pod_names = []
        @jenkins_hermes_analysis = false
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def selected_jenkins_job_url
        'http://jenkins.example.com/job/nn/'
      end

      def request_jenkins(_uri, _request, open_timeout: nil, read_timeout: nil)
        response = Net::HTTPOK.new('1.1', '200', 'OK')
        response.instance_variable_set(:@read, true)
        response.instance_variable_set(:@body, <<~LOG)
          [!] Invalid `Podfile` file: 未找到 overlay 配置文件：/Users/a1/.jenkins/workspace/nn/Podfile.overlay.config.yml.
           #  from /Users/a1/.jenkins/workspace/nn/Podfile:7
           >  source private_source
          [ERROR] CocoaPods依赖安装失败
          Finished: FAILURE
        LOG
        response
      end
    end.new(@project_dir)

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      doctor.doctor_jenkins_build
    end

    assert_includes output, '【Jenkins日志】http://jenkins.example.com/job/nn/lastBuild/consoleText'
    assert_includes output, '【失败分类】CocoaPods 配置'
    assert_includes output, 'Podfile.overlay.config.yml'
    assert_includes output, '【修复建议】优先检查打包机 cocoapods-podx 版本；如果版本过旧，请先在 Jenkins 打包机升级到最新版本。'
    assert_includes output, '【修复建议】确认发布分支包含最新 Podfile、podx.config.yml 和 cocoapods-podx 接入代码。'
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_fix_jenkins_build_previews_low_risk_actions
    fixer = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      def initialize(project_dir)
        @project_directory = project_dir
        @pod_names = []
        @dry_run = true
        @jenkins_fix_job = 'podx-upgrade'
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def selected_jenkins_job_url
        'http://jenkins.example.com/job/nn/'
      end

      def request_jenkins(_uri, _request, open_timeout: nil, read_timeout: nil)
        response = Net::HTTPOK.new('1.1', '200', 'OK')
        response.instance_variable_set(:@read, true)
        response.instance_variable_set(:@body, <<~LOG)
          [!] Invalid `Podfile` file: 未找到 overlay 配置文件：/Users/a1/.jenkins/workspace/nn/Podfile.overlay.config.yml.
          Finished: FAILURE
        LOG
        response
      end
    end.new(@project_dir)

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      fixer.fix_jenkins_build
    end

    assert_includes output, '【修复动作】升级当前机器 cocoapods-podx'
    assert_includes output, '【修复动作】触发 Jenkins 维护 job 升级打包机 cocoapods-podx 到'
    assert_includes output, '：podx-upgrade'
    assert_includes output, 'tools/cocoapods-podx.sh install'
    assert_includes output, '【修复结果】dry-run，未执行'
    assert_includes output, '【修复动作】检查当前工程 podx 接入和配置状态。'
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_fix_jenkins_build_stops_after_remote_upgrade_success
    fixer = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      def initialize(project_dir)
        @project_directory = project_dir
        @pod_names = []
        @jenkins_fix_job = 'pod-upgrade'
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def selected_jenkins_job_url
        'http://jenkins.example.com/job/nn/'
      end

      def request_jenkins(_uri, _request, open_timeout: nil, read_timeout: nil)
        response = Net::HTTPOK.new('1.1', '200', 'OK')
        response.instance_variable_set(:@read, true)
        response.instance_variable_set(:@body, <<~LOG)
          [!] Invalid `Podfile` file: 未找到 overlay 配置文件：/Users/a1/.jenkins/workspace/nn/Podfile.overlay.config.yml.
          Finished: FAILURE
        LOG
        response
      end

      def execute_remote_jenkins_fix_action(action)
        Pod::UI.puts "【修复结果】成功 #{action[:key]}"
      end

      def cocoapods_podx_version
        '0.0.99'
      end
    end.new(@project_dir)

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      fixer.fix_jenkins_build
    end

    assert_includes output, '【修复动作】触发 Jenkins 维护 job 升级打包机 cocoapods-podx 到 0.0.99：pod-upgrade'
    refute_includes output, '是否执行修复动作'
    assert_includes output, '【修复结果】成功 jenkins_upgrade_podx'
    assert_includes output, '【修复结果】打包机 cocoapods-podx 已升级到 0.0.99，请重新执行 podx publish。'
    refute_includes output, '【修复动作】升级当前机器 cocoapods-podx'
    refute_includes output, 'tools/cocoapods-podx.sh install'
    refute_includes output, '【修复动作】检查当前工程 podx 接入和配置状态。'
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_jenkins_fix_job_uses_non_parameterized_build_endpoint_first
    fixer = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      attr_reader :requested_urls

      def initialize
        @requested_urls = []
      end

      def apply_jenkins_crumb(_request, _uri); end

      def request_jenkins(uri, _request, open_timeout: nil, read_timeout: nil)
        @requested_urls << uri.to_s
        response = Net::HTTPFound.new('1.1', '302', 'Found')
        response.instance_variable_set(:@read, true)
        response['Location'] = 'http://jenkins.example.com/queue/item/1/'
        response
      end

      def wait_for_jenkins_result(*); end
    end.new

    fixer.trigger_jenkins_fix_job_with_url('http://jenkins.example.com/job/pod-upgrade/')

    assert_equal(
      ['http://jenkins.example.com/job/pod-upgrade/build'],
      fixer.requested_urls
    )
  end

  def test_jenkins_fix_job_falls_back_to_build_with_parameters
    fixer = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      attr_reader :requested_urls

      def initialize
        @requested_urls = []
      end

      def apply_jenkins_crumb(_request, _uri); end

      def request_jenkins(uri, _request, open_timeout: nil, read_timeout: nil)
        @requested_urls << uri.to_s
        if uri.to_s.end_with?('/build')
          response = Net::HTTPBadRequest.new('1.1', '400', 'Bad Request')
        else
          response = Net::HTTPFound.new('1.1', '302', 'Found')
          response['Location'] = 'http://jenkins.example.com/queue/item/1/'
        end
        response.instance_variable_set(:@read, true)
        response
      end

      def wait_for_jenkins_result(*); end
    end.new

    fixer.trigger_jenkins_fix_job_with_url('http://jenkins.example.com/job/pod-upgrade/')

    assert_equal(
      [
        'http://jenkins.example.com/job/pod-upgrade/build',
        'http://jenkins.example.com/job/pod-upgrade/buildWithParameters'
      ],
      fixer.requested_urls
    )
  end

  def test_publish_failure_auto_triggers_pod_upgrade_for_cocoapods_config
    publisher = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      attr_reader :remote_actions

      def initialize
        @remote_actions = []
      end

      def jenkins_json(_uri)
        { 'building' => false, 'result' => 'FAILURE', 'duration' => 2000 }
      end

      def print_jenkins_progress_log(_build_url, offset)
        offset
      end

      def jenkins_failure_lines(_build_url)
        [
          '[!] Invalid `Podfile` file: 未找到 overlay 配置文件：/Users/a1/.jenkins/workspace/nn/Podfile.overlay.config.yml.',
          'Finished: FAILURE'
        ]
      end

      def execute_remote_jenkins_fix_action(action)
        @remote_actions << action
        Pod::UI.puts "【修复结果】成功 #{action[:key]}"
      end

      def cocoapods_podx_version
        '0.0.99'
      end
    end.new

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      assert_raises(CocoapodsPodx::Commands::JenkinsPublish::JenkinsAutoFixApplied) do
        publisher.wait_for_jenkins_build('http://jenkins.example.com/job/nn/1/', 1, '蒲公英')
      end
    end

    assert_includes output, '【自动修复】检测到 CocoaPods 配置'
    assert_includes output, 'pod-upgrade'
    assert_includes output, '0.0.99'
    assert_equal 1, publisher.remote_actions.length
    assert_equal :jenkins_upgrade_podx, publisher.remote_actions.first[:key]
    assert_equal 'pod-upgrade', publisher.remote_actions.first[:remote_job]
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_publish_failure_does_not_auto_fix_compile_errors
    publisher = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      attr_reader :remote_actions

      def initialize
        @remote_actions = []
      end

      def jenkins_json(_uri)
        { 'building' => false, 'result' => 'FAILURE', 'duration' => 2000 }
      end

      def print_jenkins_progress_log(_build_url, offset)
        offset
      end

      def jenkins_failure_lines(_build_url)
        ['Undefined symbols for architecture arm64:', 'Finished: FAILURE']
      end

      def execute_remote_jenkins_fix_action(action)
        @remote_actions << action
      end
    end.new

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      assert_raises(Pod::Informative) do
        publisher.wait_for_jenkins_build('http://jenkins.example.com/job/nn/1/', 1, '蒲公英')
      end
    end

    refute_includes output, '【自动修复】检测到'
    assert_empty publisher.remote_actions
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_publish_failure_auto_triggers_configured_pods_fix_job
    original_job = ENV['COCOAPODS_PODX_AUTO_FIX_PODS_JOB']
    ENV['COCOAPODS_PODX_AUTO_FIX_PODS_JOB'] = 'pod-repo-update'

    publisher = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      attr_reader :remote_actions

      def initialize
        @remote_actions = []
      end

      def jenkins_json(_uri)
        { 'building' => false, 'result' => 'FAILURE', 'duration' => 2000 }
      end

      def print_jenkins_progress_log(_build_url, offset)
        offset
      end

      def jenkins_failure_lines(_build_url)
        ['[!] CocoaPods could not find compatible versions for pod "RxCocoa":', 'Finished: FAILURE']
      end

      def execute_remote_jenkins_fix_action(action)
        @remote_actions << action
        Pod::UI.puts "【修复结果】成功 #{action[:key]}"
      end
    end.new

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      assert_raises(CocoapodsPodx::Commands::JenkinsPublish::JenkinsAutoFixApplied) do
        publisher.wait_for_jenkins_build('http://jenkins.example.com/job/nn/1/', 1, '蒲公英')
      end
    end

    assert_includes output, '【自动修复】检测到 CocoaPods 依赖'
    assert_includes output, 'pod-repo-update'
    assert_equal 1, publisher.remote_actions.length
    assert_equal :jenkins_fix_pods, publisher.remote_actions.first[:key]
    assert_equal 'pod-repo-update', publisher.remote_actions.first[:remote_job]
  ensure
    ENV['COCOAPODS_PODX_AUTO_FIX_PODS_JOB'] = original_job
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_publish_failure_auto_triggers_configured_pods_fix_job_for_unsatisfied_requirements
    original_job = ENV['COCOAPODS_PODX_AUTO_FIX_PODS_JOB']
    ENV['COCOAPODS_PODX_AUTO_FIX_PODS_JOB'] = 'pod-repo-update'

    publisher = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      attr_reader :remote_actions

      def initialize
        @remote_actions = []
      end

      def jenkins_json(_uri)
        { 'building' => false, 'result' => 'FAILURE', 'duration' => 2000 }
      end

      def print_jenkins_progress_log(_build_url, offset)
        offset
      end

      def jenkins_failure_lines(_build_url)
        ['[!] Unable to satisfy the following requirements:', '- `NNLibrary (= 1.0.0)` required by `Podfile`', 'Finished: FAILURE']
      end

      def execute_remote_jenkins_fix_action(action)
        @remote_actions << action
        Pod::UI.puts "【修复结果】成功 #{action[:key]}"
      end
    end.new

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      assert_raises(CocoapodsPodx::Commands::JenkinsPublish::JenkinsAutoFixApplied) do
        publisher.wait_for_jenkins_build('http://jenkins.example.com/job/nn/1/', 1, '蒲公英')
      end
    end

    assert_includes output, '【自动修复】检测到 CocoaPods 版本约束'
    assert_includes output, 'pod-repo-update'
    assert_equal 1, publisher.remote_actions.length
    assert_equal :jenkins_fix_pods, publisher.remote_actions.first[:key]
  ensure
    ENV['COCOAPODS_PODX_AUTO_FIX_PODS_JOB'] = original_job
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_publish_failure_does_not_auto_fix_pods_without_configured_job
    original_job = ENV['COCOAPODS_PODX_AUTO_FIX_PODS_JOB']
    original_global = ENV['COCOAPODS_PODX_AUTO_FIX_JOB']
    ENV.delete('COCOAPODS_PODX_AUTO_FIX_PODS_JOB')
    ENV.delete('COCOAPODS_PODX_AUTO_FIX_JOB')

    publisher = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      attr_reader :remote_actions

      def initialize
        @remote_actions = []
      end

      def jenkins_json(_uri)
        { 'building' => false, 'result' => 'FAILURE', 'duration' => 2000 }
      end

      def print_jenkins_progress_log(_build_url, offset)
        offset
      end

      def jenkins_failure_lines(_build_url)
        ['[!] CocoaPods could not find compatible versions for pod "RxCocoa":', 'Finished: FAILURE']
      end

      def execute_remote_jenkins_fix_action(action)
        @remote_actions << action
      end
    end.new

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      assert_raises(Pod::Informative) do
        publisher.wait_for_jenkins_build('http://jenkins.example.com/job/nn/1/', 1, '蒲公英')
      end
    end

    refute_includes output, '【自动修复】检测到 CocoaPods 依赖'
    assert_empty publisher.remote_actions
  ensure
    ENV['COCOAPODS_PODX_AUTO_FIX_PODS_JOB'] = original_job
    ENV['COCOAPODS_PODX_AUTO_FIX_JOB'] = original_global
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_publish_failure_auto_triggers_configured_xcode_fix_job_for_metal_toolchain
    original_job = ENV['COCOAPODS_PODX_AUTO_FIX_XCODE_JOB']
    ENV['COCOAPODS_PODX_AUTO_FIX_XCODE_JOB'] = 'xcode-toolchain-check'

    publisher = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      attr_reader :remote_actions

      def initialize
        @remote_actions = []
      end

      def jenkins_json(_uri)
        { 'building' => false, 'result' => 'FAILURE', 'duration' => 2000 }
      end

      def print_jenkins_progress_log(_build_url, offset)
        offset
      end

      def jenkins_failure_lines(_build_url)
        [
          'xcrun: error: unable to find utility "metal", not a developer tool or in PATH',
          'Command CompileMetalFile failed with a nonzero exit code',
          'Finished: FAILURE'
        ]
      end

      def execute_remote_jenkins_fix_action(action)
        @remote_actions << action
        Pod::UI.puts "【修复结果】成功 #{action[:key]}"
      end
    end.new

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      assert_raises(CocoapodsPodx::Commands::JenkinsPublish::JenkinsAutoFixApplied) do
        publisher.wait_for_jenkins_build('http://jenkins.example.com/job/nn/1/', 1, '蒲公英')
      end
    end

    assert_includes output, '【自动修复】检测到 Xcode/SDK 环境'
    assert_includes output, 'xcode-toolchain-check'
    assert_equal 1, publisher.remote_actions.length
    assert_equal :jenkins_fix_xcode, publisher.remote_actions.first[:key]
    assert_equal 'xcode-toolchain-check', publisher.remote_actions.first[:remote_job]
  ensure
    ENV['COCOAPODS_PODX_AUTO_FIX_XCODE_JOB'] = original_job
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_analyze_jenkins_failure_reports_app_store_framework_metadata
    helper = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish
    end.new

    report = helper.analyze_jenkins_failure([
      "ERROR ITMS-90060: This bundle is invalid. The value for key CFBundleShortVersionString '1.5.0.0' in the Info.plist file at 'Payload/NNIM.app/Frameworks/libwebp.framework' must be a period-separated list of at most three non-negative integers.",
      "ERROR ITMS-90208: Invalid MinimumOSVersion. The MinimumOSVersion '' in 'Payload/NNIM.app/Frameworks/libwebp.framework' is invalid."
    ])

    assert_equal 'App Store Framework 元数据', report[:type]
    assert_includes report[:reason], 'CFBundleShortVersionString'
    assert report[:suggestions].any? { |line| line.include?('CFBundleShortVersionString') && line.include?('1.5.0') }
    assert report[:suggestions].any? { |line| line.include?('MinimumOSVersion') && line.include?('13.0') }
    assert report[:suggestions].any? { |line| line.include?('libwebp.framework') }
  end

  def test_publish_failure_auto_triggers_configured_framework_metadata_fix_job
    original_job = ENV['COCOAPODS_PODX_AUTO_FIX_FRAMEWORK_METADATA_JOB']
    ENV['COCOAPODS_PODX_AUTO_FIX_FRAMEWORK_METADATA_JOB'] = 'framework-metadata-fix'

    publisher = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      attr_reader :remote_actions

      def initialize
        @remote_actions = []
      end

      def jenkins_json(_uri)
        { 'building' => false, 'result' => 'FAILURE', 'duration' => 2000 }
      end

      def print_jenkins_progress_log(_build_url, offset)
        offset
      end

      def jenkins_failure_lines(_build_url)
        [
          "ERROR ITMS-90060: CFBundleShortVersionString '1.5.0.0' in Payload/NNIM.app/Frameworks/libwebp.framework is invalid.",
          "ERROR ITMS-90208: Invalid MinimumOSVersion in Payload/NNIM.app/Frameworks/libwebp.framework is ''.",
          'Finished: FAILURE'
        ]
      end

      def execute_remote_jenkins_fix_action(action)
        @remote_actions << action
        Pod::UI.puts "【修复结果】成功 #{action[:key]}"
      end
    end.new

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      assert_raises(CocoapodsPodx::Commands::JenkinsPublish::JenkinsAutoFixApplied) do
        publisher.wait_for_jenkins_build('http://jenkins.example.com/job/nn/1/', 1, 'TestFlight')
      end
    end

    assert_includes output, '【自动修复】检测到 App Store Framework 元数据'
    assert_includes output, 'framework-metadata-fix'
    assert_equal 1, publisher.remote_actions.length
    assert_equal :jenkins_fix_framework_metadata, publisher.remote_actions.first[:key]
    assert_equal 'framework-metadata-fix', publisher.remote_actions.first[:remote_job]
  ensure
    ENV['COCOAPODS_PODX_AUTO_FIX_FRAMEWORK_METADATA_JOB'] = original_job
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_publish_auto_fix_retries_build_once_after_fix
    publisher = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      attr_reader :calls

      def initialize
        @calls = 0
      end

      def trigger_jenkins_build(_params, _target_name)
        @calls += 1
        raise CocoapodsPodx::Commands::JenkinsPublish::JenkinsAutoFixApplied if @calls == 1
      end
    end.new

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      publisher.trigger_jenkins_build_with_auto_fix_retry({ 'branch' => 'origin/develop' }, '蒲公英')
    end

    assert_equal 2, publisher.calls
    assert_includes output, '【自动修复】修复完成，自动重新触发 Jenkins 打包（1/1）'
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_publish_syncs_local_overlay_repos_to_publish_branch_after_success
    publisher = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      attr_reader :updates

      def initialize
        @pod_names = []
        @dry_run = false
        @updates = []
      end

      def validate_jenkins_publish_context!; end

      def jenkins_publish_job_profile
        { default_channel: 'pgyer' }
      end

      def jenkins_deploy_target(_channel)
        { name: '蒲公英' }
      end

      def validate_jenkins_publish_target!(_job_profile, _target); end

      def validate_jenkins_publish_branch!(_branch, _target); end

      def jenkins_publish_branch
        'origin/release/5.14.3'
      end

      def jenkins_build_params(_job_profile, branch, _target)
        { 'branch' => branch }
      end

      def print_publish_header(_branch, _target); end

      def publish_git_rows(_branch)
        []
      end

      def print_publish_git_table(_rows); end

      def print_jenkins_progress(_message); end

      def trigger_jenkins_build_with_auto_fix_retry(_params, _target_name); end

      def load_entries
        [{ name: 'NNBussCom' }, { name: 'NNBasciCommon' }]
      end

      def update_local_repo(name, dry_run:, pull:, expected_branch:, quiet:)
        @updates << [name, dry_run, pull, expected_branch, quiet]
        true
      end
    end.new

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      publisher.publish_to_jenkins
    end

    assert_equal [
      ['NNBussCom', false, true, 'release/5.14.3', true],
      ['NNBasciCommon', false, true, 'release/5.14.3', true]
    ], publisher.updates
    assert_includes output, '【本地组件同步】'
    assert_includes output, '| NNBussCom     | release/5.14.3 | 已同步 |'
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_jenkins_build_fallback_progress_only_says_switch_when_next_url_exists
    publisher = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      def jenkins_job_urls
        ['http://jenkins.example.com/job/first/', 'http://jenkins.example.com/job/second/']
      end

      def trigger_jenkins_build_with_url(job_url, _params, _target_name)
        raise CocoapodsPodx::Commands::JenkinsPublish::JenkinsConnectionError, "failed #{job_url}"
      end
    end.new

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      assert_raises(Pod::Informative) do
        publisher.trigger_jenkins_build({ 'branch' => 'origin/develop' }, '蒲公英')
      end
    end

    assert_includes output, 'Jenkins 地址不可用：http://jenkins.example.com/job/first/，切换备用：http://jenkins.example.com/job/second/'
    assert_includes output, 'Jenkins 地址不可用：http://jenkins.example.com/job/second/'
    refute_includes output, '切换备用：http://jenkins.example.com/job/first/'
    refute_includes output, 'failed http://jenkins.example.com/job/second/'
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_publish_header_prints_selected_available_jenkins_url
    publisher = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      def jenkins_job_urls
        ['http://jenkins.example.com/job/first/', 'http://jenkins.example.com/job/second/']
      end

      def jenkins_job_available?(job_url)
        job_url.include?('/second/')
      end
    end.new

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      publisher.print_publish_header('origin/develop', { name: '蒲公英' })
    end

    prepare_lines = output.lines.select { |line| line.include?('【打包准备】') }
    assert_equal 1, prepare_lines.length
    refute_includes output, '【打包准备】探测 Jenkins http://jenkins.example.com/job/first/'
    refute_includes output, '【打包准备】Jenkins 不可用 http://jenkins.example.com/job/first/'
    assert_includes prepare_lines.first, '【打包准备】Jenkins 可用 http://jenkins.example.com/job/second/'
    assert_includes output, '【打包服务】http://jenkins.example.com/job/second/'
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_publish_remote_repo_items_use_publish_branch_for_private_repos
    project_dir = @project_dir
    publisher = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      define_method(:project_directory) do
        project_dir
      end

      def podfile_path
        File.join(project_directory, 'Podfile')
      end

      def git_repository_name
        'nnios'
      end

      def main_remote_url
        'http://git.example.com/nn_ios/nnios.git'
      end

      def publish_private_repo_names
        %w[NNApperance NNLibrary]
      end
    end.new

    items = publisher.publish_remote_repo_items('origin/develop')

    assert_equal ['nnios', 'NNApperance', 'NNLibrary'], items.map { |item| item[:repo] }
    assert_equal ['develop', 'develop', 'develop'], items.map { |item| item[:branch] }
  end

  def test_jenkins_trigger_uses_selected_url_first
    publisher = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      attr_reader :attempts

      def initialize
        @selected_jenkins_job_url = 'http://jenkins.example.com/job/second/'
        @attempts = []
      end

      def jenkins_job_urls
        ['http://jenkins.example.com/job/first/', 'http://jenkins.example.com/job/second/']
      end

      def trigger_jenkins_build_with_url(job_url, _params, _target_name)
        @attempts << job_url
        true
      end
    end.new

    publisher.trigger_jenkins_build({ 'branch' => 'origin/develop' }, '蒲公英')

    assert_equal ['http://jenkins.example.com/job/second/'], publisher.attempts
  end

  def test_jenkins_timeout_defaults_allow_slow_intranet_server
    helper = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish
    end.new

    assert_equal 15, helper.jenkins_open_timeout
    assert_equal 60, helper.jenkins_read_timeout
    assert_equal 5, helper.jenkins_probe_timeout
  end

  def test_hermes_publish_evolution_prompt_redacts_sensitive_context
    helper = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish
    end.new

    report = {
      type: 'CocoaPods 配置',
      reason: 'missing config at /Users/a1/.jenkins/workspace/nn/Podfile.overlay.config.yml'
    }
    prompt = helper.hermes_publish_evolution_prompt(
      event: 'publish_failed',
      report: report,
      target_name: '蒲公英',
      build_number: 1274,
      result: 'FAILURE',
      failure_lines: [
        'See http://10.1.3.177:8080/job/nn/1274/console',
        'password=admin123 token=abcdef /Users/a1/.jenkins/workspace/nn/Podfile'
      ],
      auto_fix: { key: :jenkins_upgrade_podx, job: 'http://10.1.3.177:8080/job/pod-upgrade/' },
      error: nil
    )

    refute_includes prompt, '10.1.3.177'
    refute_includes prompt, 'admin123'
    refute_includes prompt, 'abcdef'
    refute_includes prompt, '/Users/a1'
    assert_includes prompt, '[URL]'
    assert_includes prompt, '[PATH]'
    assert_includes prompt, 'password=[REDACTED]'
    assert_includes prompt, 'token=[REDACTED]'
  end

  def test_publish_only_can_resolve_current_git_branch
    project_dir = Dir.mktmpdir('cocoapods-podx-publish-only')
    File.write(File.join(project_dir, 'Podfile'), "target 'App' do\nend\n")
    system('git', '-C', project_dir, 'init', '-q')
    system('git', '-C', project_dir, 'checkout', '-b', 'develop', out: File::NULL, err: File::NULL)

    Dir.chdir(project_dir) do
      publisher = CocoapodsPodx::PublishOnly.new(['publish', '--job', 'nnrtc-ios-build'])
      assert_equal 'develop', publisher.main_app_branch
    end
  ensure
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_mgit_standalone_status_runs_without_cocoapods_command
    original_puts = nil
    project_dir = Dir.mktmpdir('cocoapods-podx-mgit-standalone')
    FileUtils.mkdir_p(File.join(project_dir, 'Development Pods', 'nnlibrary'))
    system('git', '-C', project_dir, 'init', '-q')
    system('git', '-C', File.join(project_dir, 'Development Pods', 'nnlibrary'), 'init', '-q')
    File.write(File.join(project_dir, 'Podfile.overlay'), "pod 'NNLibrary'\n")

    Dir.chdir(project_dir) do
      original_puts = Pod::UI.method(:puts)
      Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
      output, = capture_io do
        CocoapodsPodx::MgitStandalone.run(['status'])
      end

      assert_includes output, '【status 结果】'
      assert_includes output, '| main'
      assert_includes output, '| NNLibrary'
      assert_includes output, '| NNLibrary | main | -'
      assert_includes output, 'status [done] 1 skipped 1'
      Pod::UI.define_singleton_method(:puts, original_puts)
    end
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_mgit_publish_build_number_uses_release_version_parts
    publisher = Class.new do
      include CocoapodsPodx::Commands::MgitPublish
    end.new

    assert_equal '501402', publisher.mgit_publish_build_number('5.14.2')
    assert_equal '501410', publisher.mgit_publish_build_number('5.14.10')
  end

  def test_mgit_publish_project_specific_actions_are_opt_in
    original_config_path = CocoapodsPodx::Runtime.instance_variable_get(:@config_path)
    original_project_config = CocoapodsPodx::Runtime.instance_variable_get(:@project_config)
    generic_dir = Dir.mktmpdir('cocoapods-podx-generic-publish')
    File.write(File.join(generic_dir, 'podx.config.yml'), <<~YAML)
      target_name: generic
      git_base_url: http://git.example.com
      publish_repos:
        - app
    YAML

    CocoapodsPodx::Runtime.instance_variable_set(:@config_path, File.join(generic_dir, 'podx.config.yml'))
    CocoapodsPodx::Runtime.instance_variable_set(:@project_config, nil)

    publisher = Class.new do
      include CocoapodsPodx::Commands::MgitPublish
    end.new

    refute publisher.mgit_publish_main_repo?('app')
    refute publisher.mgit_publish_update_podfile_branch_enabled?
    refute publisher.mgit_publish_version_update_enabled?
    assert_nil publisher.mgit_publish_release_version('release/5.14.2')
    assert_nil publisher.mgit_publish_build_number('5.14.2')
  ensure
    CocoapodsPodx::Runtime.instance_variable_set(:@config_path, original_config_path)
    CocoapodsPodx::Runtime.instance_variable_set(:@project_config, original_project_config)
    FileUtils.rm_rf(generic_dir) if generic_dir
  end

  def test_mgit_publish_updates_podfile_branch_with_hashrocket_and_keyword_styles
    publisher = Class.new do
      include CocoapodsPodx::Commands::MgitPublish
    end.new
    repo_dir = Dir.mktmpdir('cocoapods-podx-publish')
    File.write(File.join(repo_dir, 'Podfile'), <<~RUBY)
      pod 'NNApperance', :branch => 'develop'
      pod 'NNLibrary', branch: 'develop'
      pod 'Alamofire', '5.11.2'
    RUBY

    assert publisher.mgit_publish_update_podfile_branch(repo_dir, 'release/5.14.2')

    content = File.read(File.join(repo_dir, 'Podfile'))
    assert_includes content, "pod 'NNApperance', :branch => 'release/5.14.2'"
    assert_includes content, "pod 'NNLibrary', branch: 'release/5.14.2'"
    assert_includes content, "pod 'Alamofire', '5.11.2'"
  ensure
    FileUtils.rm_rf(repo_dir) if repo_dir
  end

  def test_mgit_publish_syncs_overlay_repos_to_target_branch
    publisher = Class.new do
      include CocoapodsPodx::Commands::MgitPublish

      attr_reader :updates

      def initialize
        @dry_run = false
        @updates = []
      end

      def load_entries
        [{ name: 'NNBasciCommon' }, { name: 'NNBussCom' }, { name: 'NNBussCom' }]
      end

      def update_local_repo(name, dry_run:, pull:, expected_branch:)
        @updates << [name, dry_run, pull, expected_branch]
        true
      end
    end.new

    assert_equal(
      [
        ['NNBussCom', '-', 'release/5.14.2', 'ok'],
        ['NNBasciCommon', '-', 'release/5.14.2', 'ok'],
      ],
      publisher.mgit_publish_sync_overlay_repos('release/5.14.2')
    )
    assert_equal(
      [
        ['NNBussCom', false, true, 'release/5.14.2'],
        ['NNBasciCommon', false, true, 'release/5.14.2'],
      ],
      publisher.updates
    )
  end

  def test_mgit_publish_syncs_publish_repos_instead_of_only_overlay_repos
    original_config_path = CocoapodsPodx::Runtime.instance_variable_get(:@config_path)
    original_project_config = CocoapodsPodx::Runtime.instance_variable_get(:@project_config)
    project_dir = Dir.mktmpdir('cocoapods-podx-mgit-publish-sync')
    File.write(File.join(project_dir, 'podx.config.yml'), <<~YAML)
      target_name: nn_ios
      git_base_url: http://git.example.com
      publish_main_repo: nnios
      publish_repos:
        - nnios
        - nnbusscom
        - nnyytext
        - nngeneral
    YAML
    File.write(File.join(project_dir, 'Podfile'), <<~RUBY)
      pod 'NNLibrary', :branch => 'develop', :remote_name => 'NNYYText', :local_name => 'NNLibrary'
      pod 'NNLogin', :branch => 'develop', :group_name => 'NNBussCom'
      pod 'NNGeneral', :branch => 'develop'
    RUBY
    CocoapodsPodx::Runtime.configure(project_directory: project_dir)

    publisher = Class.new do
      include CocoapodsPodx::Commands::MgitPublish

      attr_reader :updates

      def initialize
        @dry_run = false
        @updates = []
      end

      def load_entries
        [{ name: 'NNLibrary' }, { name: 'NNBasciCommon' }]
      end

      def update_local_repo(name, dry_run:, pull:, expected_branch:)
        @updates << [name, dry_run, pull, expected_branch]
        true
      end
    end.new

    rows = publisher.mgit_publish_sync_local_repos('release/5.14.2')

    assert_equal(
      [
        ['NNBussCom', '-', 'release/5.14.2', 'ok'],
        ['NNLibrary', '-', 'release/5.14.2', 'ok'],
        ['NNGeneral', '-', 'release/5.14.2', 'ok'],
        ['NNBasciCommon', '-', 'release/5.14.2', 'ok'],
      ],
      rows
    )
    assert_equal(
      [
        ['NNBussCom', false, true, 'release/5.14.2'],
        ['NNLibrary', false, true, 'release/5.14.2'],
        ['NNGeneral', false, true, 'release/5.14.2'],
        ['NNBasciCommon', false, true, 'release/5.14.2'],
      ],
      publisher.updates
    )
  ensure
    CocoapodsPodx::Runtime.instance_variable_set(:@config_path, original_config_path)
    CocoapodsPodx::Runtime.instance_variable_set(:@project_config, original_project_config)
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_mgit_publish_table_output
    output = []
    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| output << message }

    publisher = Class.new do
      include CocoapodsPodx::Commands::MgitPublish
    end.new

    publisher.mgit_publish_print_table(
      '测试表格',
      [['repo', 'develop', 'release/5.14.2', 'ok']],
      headers: ['仓库', '基准分支', '发布分支', '结果']
    )

    assert_includes output.join("\n"), '【测试表格】'
    assert_includes output.join("\n"), '| 仓库'
    assert_includes output.join("\n"), 'release/5.14.2'
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_mgit_publish_checkout_project_repo_switches_to_target_branch
    publisher = Class.new do
      include CocoapodsPodx::Commands::MgitPublish

      attr_accessor :project_directory
      attr_reader :commands

      def initialize
        @dry_run = false
        @project_directory = '/tmp/app'
        @commands = []
      end

      def git_work_tree?(_path)
        true
      end

      def git_branch_for(_path)
        'develop'
      end

      def git_dirty?(_path)
        false
      end

      def run_git!(path, *args)
        @commands << [path, args]
      end

      def checkout_branch!(path, branch)
        @commands << [path, ['checkout_branch!', branch]]
      end
    end.new

    assert_equal ['app', 'develop', 'release/5.14.2', 'ok'], publisher.mgit_publish_checkout_project_repo('release/5.14.2')
    assert_equal ['/tmp/app', ['fetch', 'origin', 'release/5.14.2']], publisher.commands[0]
    assert_equal ['/tmp/app', ['checkout_branch!', 'release/5.14.2']], publisher.commands[1]
  end

  def test_overlay_file_normalizes_entries_without_blank_lines_between_components
    helper = Class.new do
      include CocoapodsPodx::Commands::OverlayFile
    end.new

    lines = [
      '# 示例：',
      '',
      "pod 'NNBasciCommon'",
      '',
      "pod 'NNLibrary'"
    ]

    assert_equal(
      ['# 示例：', '', "pod 'NNBasciCommon'", "pod 'NNLibrary'"],
      helper.normalize_overlay_spacing(lines)
    )
  end

  def test_overlay_file_is_added_to_xcodeproj_when_written
    begin
      require 'xcodeproj'
    rescue LoadError
      skip 'xcodeproj is unavailable'
    end

    project_dir = Dir.mktmpdir('cocoapods-podx-xcodeproj')
    xcodeproj_path = File.join(project_dir, 'NNIM.xcodeproj')
    Xcodeproj::Project.new(xcodeproj_path).save

    helper = Class.new do
      include CocoapodsPodx::Commands::OverlayFile

      attr_accessor :project_directory, :overlay_path
    end.new
    helper.project_directory = project_dir
    helper.overlay_path = File.join(project_dir, 'Podfile.overlay')
    helper.instance_variable_set(:@disable, false)
    helper.instance_variable_set(:@pod_names, ['NNBasciCommon'])

    helper.write_entries([])

    project = Xcodeproj::Project.open(xcodeproj_path)
    assert project.files.any? { |file| file.path == 'Podfile.overlay' }
  ensure
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_git_actions_log_limit_falls_back_to_default
    helper = Class.new do
      include CocoapodsPodx::Commands::GitActions
    end.new

    helper.instance_variable_set(:@log_limit, 'bad')
    assert_equal '5', helper.log_limit

    helper.instance_variable_set(:@log_limit, '12')
    assert_equal '12', helper.log_limit
  end

  def test_git_actions_add_ignores_git_add_pathspec_aliases
    helper = Class.new do
      include CocoapodsPodx::Commands::GitActions
    end.new

    helper.instance_variable_set(:@add_mode, true)
    helper.instance_variable_set(:@pod_names, ['.', '-A', '--all', 'NNBussCom'])
    helper.normalize_git_add_arguments!

    assert_equal ['NNBussCom'], helper.instance_variable_get(:@pod_names)
  end

  def test_git_actions_pull_table_uses_compact_aligned_columns
    helper = Class.new do
      include CocoapodsPodx::Commands::GitActions
    end.new

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      helper.git_action_print_table(
        'pull 结果',
        %w[仓库 分支 更新状态 Commit],
        [
          ['main', 'feature/5.14.2_broadcast', '有更新', 'bd5ad0 update: 发布cocoapods-podx 0.0.35'],
          ['NNBussCom', 'feature/5.14.2_broadcast', '无更新', '-']
        ]
      )
    end

    assert_includes output, '【pull 结果】'
    assert_includes output, '| 仓库'
    refute_includes output, '路径'
    assert_includes output, '有更新'
    assert_includes output, 'bd5ad0 update'

    table_lines = output.lines.map(&:chomp).select { |line| line.start_with?('|', '+') }
    widths = table_lines.map { |line| helper.git_action_display_width(line) }
    assert_equal 1, widths.uniq.length
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_git_actions_pull_switches_clean_components_to_main_branch_before_pull
    project_dir = Dir.mktmpdir('cocoapods-podx-git-actions')
    main_path = File.join(project_dir, 'main')
    component_path = File.join(project_dir, 'Development Pods', 'NNApperance')
    FileUtils.mkdir_p(main_path)
    FileUtils.mkdir_p(component_path)

    helper = Class.new do
      include CocoapodsPodx::Commands::GitActions

      attr_reader :commands

      def initialize(project_directory, component_path)
        @project_directory = project_directory
        @component_path = component_path
        @pull_mode = true
        @pod_names = []
        @dry_run = false
        @commands = []
        @branches = {
          project_directory => 'feature/5.14.2_broadcast',
          component_path => 'release/5.14.3'
        }
        @heads = Hash.new('aaaaaa')
      end

      def project_directory
        @project_directory
      end

      def commit_targets(_entries)
        [
          { name: 'main', path: @project_directory },
          { name: 'NNApperance', path: @component_path }
        ]
      end

      def git_work_tree?(_path)
        true
      end

      def git_branch_for(path)
        @branches[path]
      end

      def git_status_lines(_path)
        []
      end

      def git_dirty?(_path)
        false
      end

      def run_git!(path, *args)
        @commands << [path, args]
        @heads[path] = 'bbbbbb' if args == ['pull', '--ff-only', 'origin', @branches[path]]
        ''
      end

      def checkout_branch!(path, branch)
        @commands << [path, ['checkout_branch!', branch]]
        @branches[path] = branch
      end

      def git_short_head(path)
        @heads[path]
      end

      def git_commit_summary(_path, commit)
        "#{commit} update"
      end
    end.new(main_path, component_path)

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      helper.git_action_repos([])
    end

    assert_includes output, '| NNApperance | feature/5.14.2_broadcast | 有更新'
    assert_includes output, 'bbbbbb update'
    assert_includes helper.commands, [component_path, ['fetch', 'origin']]
    assert_includes helper.commands, [component_path, ['checkout_branch!', 'feature/5.14.2_broadcast']]
    assert_includes helper.commands, [component_path, ['pull', '--ff-only', 'origin', 'feature/5.14.2_broadcast']]
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_git_actions_merge_named_component_from_origin_branch
    project_dir = Dir.mktmpdir('cocoapods-podx-git-merge')
    main_path = File.join(project_dir, 'main')
    component_path = File.join(project_dir, 'Development Pods', 'NNBussCom')
    FileUtils.mkdir_p(main_path)
    FileUtils.mkdir_p(component_path)

    helper = Class.new do
      include CocoapodsPodx::Commands::GitActions

      attr_reader :commands

      def initialize(main_path, component_path)
        @project_directory = main_path
        @component_path = component_path
        @merge_mode = true
        @merge_branch = 'develop'
        @pod_names = ['NNBussCom']
        @dry_run = false
        @commands = []
        @branches = {
          main_path => 'feature/5.14.2_broadcast',
          component_path => 'feature/5.14.2_broadcast'
        }
        @heads = {
          component_path => '1111111111111111111111111111111111111111'
        }
      end

      def project_directory
        @project_directory
      end

      def commit_targets(_entries)
        [{ name: 'NNBussCom', path: @component_path }]
      end

      def git_work_tree?(_path)
        true
      end

      def git_branch_for(path)
        @branches[path]
      end

      def git_status_lines(_path)
        []
      end

      def git_dirty?(_path)
        false
      end

      def git_full_head(path)
        @heads[path]
      end

      def run_git!(path, *args)
        @commands << [path, args]
        @heads[path] = '2222222222222222222222222222222222222222' if args == ['merge', '--no-edit', '--no-stat', 'origin/develop']
        ''
      end

      def git_commit_summary(_path, commit)
        "#{commit[0, 6]} merge"
      end
    end.new(main_path, component_path)

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      helper.git_action_repos([])
    end

    assert_includes output, '【merge 结果】'
    assert_includes output, '| NNBussCom | feature/5.14.2_broadcast | 已合并 |'
    assert_includes helper.commands, [component_path, ['fetch', 'origin', 'develop']]
    assert_includes helper.commands, [component_path, ['merge', '--no-edit', '--no-stat', 'origin/develop']]
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_git_actions_status_table_shows_filenames_without_paths
    helper = Class.new do
      include CocoapodsPodx::Commands::GitActions
    end.new

    assert_equal 'LoginLogic.swift', helper.git_changed_file_summary([' M NNIM/Src/Main/Auth/Logics/LoginLogic.swift'])
    assert_equal 'NewName.swift', helper.git_changed_file_summary(['R  Old/OldName.swift -> New/Path/NewName.swift'])

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      helper.git_action_print_table(
        'status 结果',
        %w[仓库 分支 变更],
        [
          ['main', 'feature/5.14.2_broadcast', 'LoginLogic.swift'],
          ['NNBussCom', 'feature/5.14.2_broadcast', 'NNVoiceRoomViewController.swift'],
          ['NNApperance', 'feature/5.14.2_broadcast', '-']
        ]
      )
    end

    assert_includes output, 'LoginLogic.swift'
    refute_includes output, 'NNIM/Src/Main/Auth'
    assert_includes output, 'NNVoiceRoomViewController.swift'

    table_lines = output.lines.map(&:chomp).select { |line| line.start_with?('|', '+') }
    widths = table_lines.map { |line| helper.git_action_display_width(line) }
    assert_equal 1, widths.uniq.length
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_git_actions_simple_action_table_uses_three_aligned_columns
    helper = Class.new do
      include CocoapodsPodx::Commands::GitActions
    end.new

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      helper.git_action_print_table(
        'add 结果',
        %w[仓库 分支 状态],
        [
          helper.git_simple_action_table_row(['main', 'feature/5.14.2_broadcast', 'added', 'M LoginLogic.swift', '/tmp/main']),
          helper.git_simple_action_table_row(['NNBussCom', 'feature/5.14.2_broadcast', 'skip', 'clean', '/tmp/nnbusscom']),
          helper.git_simple_action_table_row(['NNLibrary', 'feature/5.14.2_broadcast', 'pushed', 'origin/feature/5.14.2_broadcast', '/tmp/NNLibrary'])
        ]
      )
    end

    assert_includes output, '| 仓库'
    assert_includes output, '已暂存'
    assert_includes output, '跳过'
    assert_includes output, '已推送'
    refute_includes output, '详情'
    refute_includes output, '路径'
    refute_includes output, '/tmp'

    table_lines = output.lines.map(&:chomp).select { |line| line.start_with?('|', '+') }
    widths = table_lines.map { |line| helper.git_action_display_width(line) }
    assert_equal 1, widths.uniq.length
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_git_actions_push_marks_only_ahead_repos_as_pushed
    project_dir = Dir.mktmpdir('cocoapods-podx-git-push')
    main_path = File.join(project_dir, 'main')
    component_path = File.join(project_dir, 'Development Pods', 'NNBasciCommon')
    FileUtils.mkdir_p(main_path)
    FileUtils.mkdir_p(component_path)

    helper = Class.new do
      include CocoapodsPodx::Commands::GitActions

      attr_reader :commands

      def initialize(main_path, component_path)
        @project_directory = main_path
        @component_path = component_path
        @push_mode = true
        @pod_names = []
        @dry_run = false
        @commands = []
        @branches = {
          main_path => 'feature/5.14.2_broadcast',
          component_path => 'feature/5.14.2_broadcast'
        }
        @local_heads = {
          main_path => '1111111111111111111111111111111111111111',
          component_path => '2222222222222222222222222222222222222222'
        }
        @remote_heads = {
          main_path => '1111111111111111111111111111111111111111',
          component_path => 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        }
      end

      def project_directory
        @project_directory
      end

      def commit_targets(_entries)
        [
          { name: 'main', path: @project_directory },
          { name: 'NNBasciCommon', path: @component_path }
        ]
      end

      def git_work_tree?(_path)
        true
      end

      def git_branch_for(path)
        @branches[path]
      end

      def git_status_lines(_path)
        []
      end

      def run_git!(path, *args)
        @commands << [path, args]
        ''
      end

      def git_full_head(path)
        @local_heads[path]
      end

      def git_remote_head(path, _branch)
        @remote_heads[path]
      end

      def git_commit_summary(_path, commit)
        "#{commit[0, 6]} commit"
      end
    end.new(main_path, component_path)

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      helper.git_action_repos([])
    end

    assert_includes output, '| main          | feature/5.14.2_broadcast | 无更新 |'
    assert_includes output, '| NNBasciCommon | feature/5.14.2_broadcast | 已推送 |'
    assert_includes helper.commands, [component_path, ['push', 'origin', 'feature/5.14.2_broadcast']]
    refute_includes helper.commands, [main_path, ['push', 'origin', 'feature/5.14.2_broadcast']]
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_git_actions_stash_table_shows_change_summary
    helper = Class.new do
      include CocoapodsPodx::Commands::GitActions
    end.new

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      helper.git_action_print_table(
        'stash 结果',
        %w[仓库 分支 变更],
        [
          helper.git_stash_table_row(['main', 'feature/5.14.2_broadcast', 'stashed', 'LoginLogic.swift', '/tmp/main']),
          helper.git_stash_table_row(['NNBussCom', 'feature/5.14.2_broadcast', 'skip', 'clean', '/tmp/nnbusscom'])
        ]
      )
    end

    assert_includes output, '| 仓库'
    assert_includes output, 'LoginLogic.swift'
    refute_includes output, '路径'
    refute_includes output, '/tmp'

    table_lines = output.lines.map(&:chomp).select { |line| line.start_with?('|', '+') }
    widths = table_lines.map { |line| helper.git_action_display_width(line) }
    assert_equal 1, widths.uniq.length
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_git_actions_checkout_table_uses_three_aligned_columns
    helper = Class.new do
      include CocoapodsPodx::Commands::GitActions
    end.new

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      helper.git_action_print_table(
        'checkout 结果',
        %w[仓库 分支 状态],
        [
          helper.git_simple_action_table_row(['main', 'release/5.14.2', 'checkout', '-> release/5.14.2', '/tmp/main']),
          helper.git_simple_action_table_row(['NNBussCom', 'feature/5.14.2_broadcast', 'skip', 'dirty', '/tmp/nnbusscom'])
        ]
      )
    end

    assert_includes output, '已切换'
    assert_includes output, '跳过'
    refute_includes output, '详情'
    refute_includes output, '路径'
    refute_includes output, '/tmp'

    table_lines = output.lines.map(&:chomp).select { |line| line.start_with?('|', '+') }
    widths = table_lines.map { |line| helper.git_action_display_width(line) }
    assert_equal 1, widths.uniq.length
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_jenkins_publish_format_helpers
    helper = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish
    end.new

    assert_equal 'abcdef', helper.short_commit('abcdef123456')
    assert_equal '[==========----------]', helper.progress_bar(1, 2)
    assert_operator helper.display_width('提交'), :>, helper.display_width('ab')
    assert_equal 4, helper.display_width('提交')
    assert_equal 1, helper.display_width('…')
    assert_equal 28, helper.display_width(helper.truncate_display('origin/feature/5.14.2_broadcast', 28))
    assert_includes helper.truncate_display('origin/feature/5.14.2_broadcast', 28), '...'
    assert_equal "binarytext", helper.safe_jenkins_text("binary\xFFtext".b)
  end

  def test_jenkins_publish_password_defaults
    helper = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish
    end.new

    assert_equal ',', helper.jenkins_publish_password_for(name: '蒲公英', value: 'Pgyer,')

    helper.instance_variable_set(:@dry_run, true)
    assert_equal '***,', helper.jenkins_publish_password_for(name: 'TestFlight', value: 'TestFlight,')
  end

  def test_jenkins_publish_password_validates_before_triggering_build
    helper = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish
    end.new

    helper.instance_variable_set(:@publish_password, 'wrong')
    error = assert_raises(Pod::Informative) do
      helper.jenkins_build_params({ branch_param: 'branch', source_param: nil }, 'origin/release/5.14.2', name: 'TestFlight', value: 'TestFlight,', kind: :app)
    end

    assert_includes error.message, '打包密码错误'

    helper.instance_variable_set(:@publish_password, 'admin123')
    params = helper.jenkins_build_params({ branch_param: 'branch', source_param: nil }, 'origin/release/5.14.2', name: 'TestFlight', value: 'TestFlight,', kind: :app)
    assert_equal 'admin123,', params['VERIFICATION_PASSWORD']
  end

  def test_jenkins_publish_release_branch_validation
    helper = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish
    end.new

    helper.validate_jenkins_publish_branch!('origin/release/5.14.2', name: 'TestFlight', value: 'TestFlight,')
    helper.validate_jenkins_publish_branch!('release/5.14.2', name: '苹果商店', value: 'AppStore,')
    helper.validate_jenkins_publish_branch!('origin/develop', name: '蒲公英', value: 'Pgyer,')

    error = assert_raises(Pod::Informative) do
      helper.validate_jenkins_publish_branch!('origin/develop', name: 'TestFlight', value: 'TestFlight,')
    end
    assert_includes error.message, '只能发布 release/x.x.x 分支'
  end

  def test_jenkins_publish_default_job_urls
    helper = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish
    end.new

    urls = helper.default_jenkins_job_urls('nnrtc-ios-build')
    assert_equal 'http://10.1.3.177:8080/job/nnrtc-ios-build/', urls[0]
    assert_equal 'http://10.1.107.211:8080/job/nnrtc-ios-build/', urls[1]

    configured_urls = helper.jenkins_job_urls_from_configured_url('http://10.1.3.177:8080/job/nn/')
    assert_equal 'http://10.1.3.177:8080/job/nn/', configured_urls[0]
    assert_equal 'http://10.1.107.211:8080/job/nn/', configured_urls[1]
  end

  def test_jenkins_publish_requires_job_outside_podfile_project
    helper = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      attr_writer :project_directory

      def project_directory
        @project_directory
      end

      def podfile_path
        File.join(project_directory, 'Podfile')
      end
    end.new
    helper.project_directory = Dir.mktmpdir('cocoapods-podx-no-podfile')

    error = assert_raises(Pod::Informative) { helper.validate_jenkins_publish_context! }
    assert_includes error.message, '--job nnrtc-ios-build'

    helper.instance_variable_set(:@jenkins_job, 'nnrtc-ios-build')
    helper.validate_jenkins_publish_context!
  ensure
    FileUtils.rm_rf(helper.project_directory) if helper&.project_directory
  end

  def test_jenkins_publish_profile_uses_job_parameters
    helper = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      attr_accessor :definitions

      def configured_jenkins_job_name
        @job_name
      end

      def job_name=(value)
        @job_name = value
      end

      def jenkins_parameter_definitions
        definitions
      end
    end.new

    helper.job_name = 'nn'
    helper.definitions = [
      { 'name' => 'branch' },
      { 'name' => 'DEPLOY_TARGET' },
      { 'name' => 'VERIFICATION_PASSWORD' },
      { 'name' => 'PODX_TRIGGER_SOURCE' }
    ]
    app_profile = helper.jenkins_publish_job_profile
    assert_equal :app, app_profile[:kind]
    assert_equal 'pgyer', app_profile[:default_channel]
    assert_equal 'branch', app_profile[:branch_param]
    assert_equal 'PODX_TRIGGER_SOURCE', app_profile[:source_param]
    params = helper.jenkins_build_params(app_profile, 'origin/develop', helper.jenkins_deploy_target('pgyer'))
    assert_equal 'podx publish', params['PODX_TRIGGER_SOURCE']
    helper.validate_jenkins_publish_target!(app_profile, helper.jenkins_deploy_target('tf'))

    error = assert_raises(Pod::Informative) do
      helper.validate_jenkins_publish_target!(app_profile, helper.jenkins_deploy_target('framework'))
    end
    assert_includes error.message, '支持 pgyer/tf/app'

    helper.remove_instance_variable(:@jenkins_publish_job_profile)
    helper.job_name = 'nnrtc-ios-build'
    helper.definitions = [{ 'name' => 'BRANCH' }]
    framework_profile = helper.jenkins_publish_job_profile
    assert_equal :framework, framework_profile[:kind]
    assert_equal 'framework', framework_profile[:default_channel]
    assert_equal 'BRANCH', framework_profile[:branch_param]
    helper.validate_jenkins_publish_target!(framework_profile, helper.jenkins_deploy_target('framework'))

    error = assert_raises(Pod::Informative) do
      helper.validate_jenkins_publish_target!(framework_profile, helper.jenkins_deploy_target('app'))
    end
    assert_includes error.message, '仅支持打 Framework'
  end

  def test_local_overlay_uses_development_pods_directory
    FileUtils.mkdir_p(File.join(@project_dir, 'Development Pods', 'NNLibrary'))
    Dir.chdir(@project_dir) do
      `git init -q`
      `git checkout -b develop >/dev/null 2>&1`
    end
    Dir.chdir(File.join(@project_dir, 'Development Pods', 'NNLibrary')) do
      `git init -q`
      `git checkout -b develop >/dev/null 2>&1`
    end
    File.write(File.join(@project_dir, 'Podfile.overlay'), "pod 'NNLibrary'\n")
    CocoapodsPodx::Runtime.configure(project_directory: @project_dir)

    options = CocoapodsPodx::Runtime.pod_options_for(name: 'NNLibrary')

    assert_equal './Development Pods/NNLibrary', options[:path]
  end

  def test_local_overlay_clones_missing_development_pod_during_pod_install
    remote_base = File.join(@project_dir, 'remotes')
    remote_repo = File.join(remote_base, 'nn_ios', 'nnyytext.git')
    FileUtils.mkdir_p(remote_repo)
    Dir.chdir(remote_repo) do
      `git init -q`
      `git config user.email test@example.com`
      `git config user.name Test`
      File.write('README.md', "fixture\n")
      `git add README.md`
      `git commit -q -m init`
      `git checkout -b develop >/dev/null 2>&1`
    end

    File.write(File.join(@project_dir, 'podx.config.yml'), <<~YAML)
      target_name: nn_ios
      private_source: #{remote_base}/nn_ios/specs.git
      git_base_url: #{remote_base}
    YAML
    Dir.chdir(@project_dir) do
      `git init -q`
      `git checkout -b develop >/dev/null 2>&1`
    end
    File.write(File.join(@project_dir, 'Podfile.overlay'), "pod 'NNLibrary'\n")
    CocoapodsPodx::Runtime.configure(project_directory: @project_dir)

    options = CocoapodsPodx::Runtime.pod_options_for(name: 'NNLibrary')

    assert_equal './Development Pods/NNLibrary', options[:path]
    assert File.directory?(File.join(@project_dir, 'Development Pods', 'NNLibrary', '.git'))
  end
end
