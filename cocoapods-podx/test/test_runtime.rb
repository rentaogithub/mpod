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

module Pod
  class Command
    class << self
      attr_accessor :summary, :description, :arguments

      def options
        []
      end
    end

    def initialize(*); end

    def validate!; end

    def help!(message)
      raise Pod::Informative, message
    end
  end
end unless defined?(Pod::Command)

module CLAide
  class Argument
    def initialize(*); end
  end
end unless defined?(CLAide::Argument)

require_relative '../lib/cocoapods_podx/commands/git_actions'
require_relative '../lib/cocoapods_podx/commands/git_hooks'
require_relative '../lib/cocoapods_podx/commands/dependency_report'
require_relative '../lib/cocoapods_podx/commands/skill_runtime'
require_relative '../lib/cocoapods_podx/commands/pipeline_runtime'
require_relative '../lib/cocoapods_podx/commands/jenkins_publish'
require_relative '../lib/cocoapods_podx/commands/mgit_publish'
require_relative '../lib/cocoapods_podx/commands/overlay_file'
require_relative '../lib/cocoapods_podx/ai_bootstrap'
require_relative '../lib/cocoapods_podx/mgit_standalone'
require_relative '../lib/cocoapods_podx/publish_only'
require_relative '../lib/cocoapods_podx/rules'
require_relative '../lib/cocoapods_podx/runtime'
require_relative '../lib/cocoapods_podx/shim_generator'
require_relative '../lib/pod/command/podx'

class CocoapodsPodxRuntimeTest < Minitest::Test
  class FakeArgv
    def initialize(options: {}, flags: {})
      @options = options
      @flags = flags
    end

    def option(name)
      @options[name]
    end

    def flag?(name, default = nil)
      @flags.key?(name) ? @flags[name] : default
    end

    def arguments!
      []
    end
  end

  def setup
    @project_dir = Dir.mktmpdir('cocoapods-podx-test')
    File.write(File.join(@project_dir, 'podx.config.yml'), <<~YAML)
      target_name: nn_ios
      private_source: http://git.example.com/nn_ios/specs.git
      git_base_url: http://git.example.com
      publish_work_dir: .mgit-publish
      publish_base_branch: develop
      publish_pipeline_gate: false
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

  def with_stubbed_runtime_remote_commit(value)
    singleton = class << CocoapodsPodx::Runtime; self; end
    original = CocoapodsPodx::Runtime.method(:remote_branch_commit_hash)
    singleton.define_method(:remote_branch_commit_hash) { |_url, _branch| value }
    yield
  ensure
    singleton.define_method(:remote_branch_commit_hash, original) if original
  end

  def write_podfile_lock_checkout_options(commit: 'abcdef123456')
    File.write(File.join(@project_dir, 'Podfile.lock'), <<~YAML)
      PODS:
        - NNLibrary

      CHECKOUT OPTIONS:
        NNLibrary:
          :git: http://git.example.com/nn_ios/nnyytext.git
          :commit: #{commit}
    YAML
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

  def test_mgit_checkout_requires_branch_when_only_component_name_is_given
    Dir.chdir(@project_dir) do
      error = assert_raises(Pod::Informative) do
        CocoapodsPodx::MgitStandalone.new(['checkout', 'NNLibrary'])
      end

      assert_includes error.message, '缺少 checkout 目标分支'
      assert_includes error.message, 'mgit checkout NNLibrary BRANCH'
    end
  end

  def test_mgit_merge_requires_branch_when_only_component_name_is_given
    Dir.chdir(@project_dir) do
      error = assert_raises(Pod::Informative) do
        CocoapodsPodx::MgitStandalone.new(['merge', 'NNBussCom'])
      end

      assert_includes error.message, '缺少 merge 来源分支'
      assert_includes error.message, 'mgit merge NNBussCom BRANCH'
    end
  end

  def test_mgit_checkout_and_merge_accept_single_branch_for_all_repos
    Dir.chdir(@project_dir) do
      checkout = CocoapodsPodx::MgitStandalone.new(['checkout', 'release/5.14.2'])
      merge = CocoapodsPodx::MgitStandalone.new(['merge', 'develop'])

      assert_equal 'release/5.14.2', checkout.instance_variable_get(:@checkout_branch)
      assert_equal 'develop', merge.instance_variable_get(:@merge_branch)
    end
  end

  def test_mgit_checkout_accepts_git_style_create_branch_options
    Dir.chdir(@project_dir) do
      short = CocoapodsPodx::MgitStandalone.new(['checkout', '-b', 'feature/5.14.5_felix_test'])
      long = CocoapodsPodx::MgitStandalone.new(['checkout', '--branch', 'feature/5.14.5_felix_test'])
      long_equal = CocoapodsPodx::MgitStandalone.new(['checkout', '--branch=feature/5.14.5_felix_test'])

      [short, long, long_equal].each do |command|
        assert command.instance_variable_get(:@checkout_create_branch)
        assert_equal 'feature/5.14.5_felix_test', command.instance_variable_get(:@checkout_branch)
        assert_empty command.instance_variable_get(:@pod_names)
      end
    end
  end

  def test_mgit_pull_defaults_to_rebase_and_accepts_ff_only_option
    Dir.chdir(@project_dir) do
      default_command = CocoapodsPodx::MgitStandalone.new(['pull', 'NNLibrary'])
      ff_only_command = CocoapodsPodx::MgitStandalone.new(['pull', '--ff-only', 'NNLibrary'])

      assert default_command.instance_variable_get(:@pull_mode)
      refute default_command.instance_variable_get(:@pull_ff_only)
      assert_equal ['NNLibrary'], default_command.instance_variable_get(:@pod_names)
      assert ff_only_command.instance_variable_get(:@pull_ff_only)
      assert_equal ['NNLibrary'], ff_only_command.instance_variable_get(:@pod_names)
    end
  end

  def test_mgit_rebase_accepts_continue_and_abort
    Dir.chdir(@project_dir) do
      continue_command = CocoapodsPodx::MgitStandalone.new(['rebase', '--continue'])
      abort_command = CocoapodsPodx::MgitStandalone.new(['rebase', '--abort'])

      assert continue_command.instance_variable_get(:@rebase_mode)
      assert continue_command.instance_variable_get(:@rebase_continue_mode)
      assert abort_command.instance_variable_get(:@rebase_mode)
      assert abort_command.instance_variable_get(:@rebase_abort_mode)
    end
  end

  def test_mgit_rebase_requires_continue_or_abort
    Dir.chdir(@project_dir) do
      error = assert_raises(Pod::Informative) do
        CocoapodsPodx::MgitStandalone.new(['rebase'])
      end

      assert_includes error.message, 'mgit rebase 只支持 --continue 或 --abort'
    end
  end

  def test_mgit_local_repo_path_uses_existing_development_pods_without_podfile_parse
    Dir.mktmpdir('cocoapods-podx-mgit-fast-path') do |project_dir|
      FileUtils.mkdir_p(File.join(project_dir, '.git'))
      FileUtils.mkdir_p(File.join(project_dir, 'Development Pods', 'NNLibrary'))

      singleton = class << CocoapodsPodx::Runtime; self; end
      original = CocoapodsPodx::Runtime.method(:local_repo_folder_name_for)
      singleton.define_method(:local_repo_folder_name_for) { |_name| raise 'should not parse Podfile' }

      Dir.chdir(project_dir) do
        command = CocoapodsPodx::MgitStandalone.new(['status', 'NNLibrary'])
        assert_equal(
          File.realpath(File.join(project_dir, 'Development Pods', 'NNLibrary')),
          command.send(:local_repo_path_for, 'NNLibrary')
        )
      end
    ensure
      singleton.define_method(:local_repo_folder_name_for, original) if singleton && original
    end
  end

  def test_mgit_local_repo_path_falls_back_to_runtime_for_group_repo_folder
    Dir.mktmpdir('cocoapods-podx-mgit-fallback-path') do |project_dir|
      FileUtils.mkdir_p(File.join(project_dir, '.git'))
      FileUtils.mkdir_p(File.join(project_dir, 'Development Pods', 'nnbusscom'))

      singleton = class << CocoapodsPodx::Runtime; self; end
      original = CocoapodsPodx::Runtime.method(:local_repo_folder_name_for)
      singleton.define_method(:local_repo_folder_name_for) { |_name| 'nnbusscom' }

      Dir.chdir(project_dir) do
        command = CocoapodsPodx::MgitStandalone.new(['status', 'NNLogin'])
        assert_equal(
          File.realpath(File.join(project_dir, 'Development Pods', 'nnbusscom')),
          command.send(:local_repo_path_for, 'NNLogin')
        )
      end
    ensure
      singleton.define_method(:local_repo_folder_name_for, original) if singleton && original
    end
  end

  def test_mgit_checkout_create_branch_creates_local_branch_when_remote_missing
    command = CocoapodsPodx::MgitStandalone.allocate
    calls = []
    command.instance_variable_set(:@checkout_create_branch, true)
    command.define_singleton_method(:git_local_branch_exists?) { |_path, _branch| false }
    command.define_singleton_method(:git_remote_branch_exists?) { |_path, _branch| false }
    command.define_singleton_method(:run_git!) { |path, *args| calls << [path, args] }

    command.send(:checkout_branch!, '/tmp/repo', 'feature/5.14.5_felix_test')

    assert_equal [['/tmp/repo', ['checkout', '-b', 'feature/5.14.5_felix_test']]], calls
  end

  def test_mgit_checkout_and_merge_reject_help_placeholders
    Dir.chdir(@project_dir) do
      checkout_error = assert_raises(Pod::Informative) do
        CocoapodsPodx::MgitStandalone.new(['checkout', 'BRANCH'])
      end
      assert_includes checkout_error.message, 'checkout 目标分支不能使用示例占位符'

      merge_error = assert_raises(Pod::Informative) do
        CocoapodsPodx::MgitStandalone.new(['merge', 'release/x.x.x'])
      end
      assert_includes merge_error.message, 'merge 来源分支不能使用示例占位符'
    end
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
    options = with_stubbed_runtime_remote_commit('abcdef') do
      CocoapodsPodx::Runtime.pod_options_for(name: 'NNLibrary')
    end

    assert_equal 'http://git.example.com/nn_ios/nnyytext.git', options[:git]
    assert_equal 'develop', options[:branch]
    assert_equal false, options[:inhibit_warnings]
  end

  def test_pod_install_runtime_output_is_structured
    write_podfile_lock_checkout_options(commit: 'abcdef123456')

    with_stubbed_runtime_remote_commit('abcdef') do
      output = capture_io do
        CocoapodsPodx::Runtime.pod_options_for(name: 'NNLibrary')
      end.first

      assert_includes output, '【podx install】依赖来源'
      assert_includes output, '| 组件'
      assert_includes output, '| 来源'
      assert_includes output, '| 分支'
      assert_includes output, '| Commit'
      assert_includes output, '| 更新'
      assert_includes output, '| 状态'
      assert_includes output, '| 主仓库'
      assert_includes output, '| NNLibrary'
      assert_includes output, '| 远端'
      assert_includes output, '| develop'
      assert_includes output, '| abcdef'
      assert_includes output, '| 正常'
      refute_includes output, 'http://git.example.com/nn_ios/nnyytext.git'
    end
  end

  def test_pod_install_runtime_prints_repo_update_hint_when_remote_lock_commit_is_behind
    write_podfile_lock_checkout_options(commit: '111111123456')

    output = with_stubbed_runtime_remote_commit('222222') do
      capture_io do
        CocoapodsPodx::Runtime.pod_options_for(name: 'NNLibrary')
        CocoapodsPodx::Runtime.send(:print_install_dependency_table_footer)
      end.first
    end

    assert_match(/\| NNLibrary\s+\| 远端 \| develop\s+\| 111111 \| 有更新 \| 正常 \|/, output)
    assert_includes output, '【podx install】提示 使用 podx install --repo-update'
  end

  def test_pod_install_runtime_records_remote_updates_without_hint_during_repo_update
    write_podfile_lock_checkout_options(commit: '111111123456')
    updates_file = File.join(@project_dir, 'remote-updates.txt')
    ENV['COCOAPODS_PODX_REPO_UPDATE'] = '1'
    ENV['COCOAPODS_PODX_REMOTE_UPDATES_FILE'] = updates_file

    output = with_stubbed_runtime_remote_commit('222222') do
      capture_io do
        CocoapodsPodx::Runtime.pod_options_for(name: 'NNLibrary')
        CocoapodsPodx::Runtime.send(:print_install_dependency_table_footer)
      end.first
    end

    assert_match(/\| NNLibrary\s+\| 远端 \| develop\s+\| 111111 \| 有更新 \| 正常 \|/, output)
    refute_includes output, '【podx install】提示 使用 podx install --repo-update'
    assert_equal "NNLibrary\n", File.read(updates_file)
  ensure
    ENV.delete('COCOAPODS_PODX_REPO_UPDATE')
    ENV.delete('COCOAPODS_PODX_REMOTE_UPDATES_FILE')
  end

  def test_pod_install_runtime_prints_mgit_pull_hint_when_local_has_updates
    output = capture_io do
      CocoapodsPodx::Runtime.send(
        :print_install_dependency_row,
        name: 'NNLibrary',
        source: '本地',
        branch: 'develop',
        commit: 'abcdef',
        update: '有更新'
      )
      CocoapodsPodx::Runtime.instance_variable_set(:@install_table_has_updates, true)
      CocoapodsPodx::Runtime.send(:print_install_dependency_table_footer)
    end.first

    assert_includes output, '有更新'
    assert_includes output, '【podx install】提示 使用mgit pull命令更新代码'
  end

  def test_pod_install_runtime_table_lines_are_aligned
    with_stubbed_runtime_remote_commit('abcdef') do
      output = capture_io do
        CocoapodsPodx::Runtime.pod_options_for(name: 'NNLibrary')
      end.first

      table_lines = output.lines.map(&:chomp).select { |line| line.start_with?('+', '|') }
      widths = table_lines.map { |line| CocoapodsPodx::Runtime.send(:install_table_display_width, line) }

      assert_operator table_lines.length, :>=, 4
      assert_equal 1, widths.uniq.length
      assert_equal 4, CocoapodsPodx::Runtime.send(:install_table_display_width, "\e[32m正常\e[0m")
    end
  end

  def test_pod_install_runtime_colors_only_local_source_and_actionable_states
    previous_no_color = ENV['NO_COLOR']
    original_color_enabled = CocoapodsPodx::Runtime.method(:install_table_color_enabled?)
    ENV.delete('NO_COLOR')
    CocoapodsPodx::Runtime.singleton_class.define_method(:install_table_color_enabled?) { true }

    local = CocoapodsPodx::Runtime.send(:color_install_table_value, '本地', '本地')
    update = CocoapodsPodx::Runtime.send(:color_install_table_value, '有更新', '有更新')
    remote = CocoapodsPodx::Runtime.send(:color_install_table_value, '远端', '远端')
    no_update = CocoapodsPodx::Runtime.send(:color_install_table_value, '-', '-')

    assert_includes local, "\e[36m"
    assert_includes update, "\e[36m"
    assert_equal '远端', remote
    assert_equal '-', no_update
  ensure
    ENV['NO_COLOR'] = previous_no_color if previous_no_color
    ENV.delete('NO_COLOR') if previous_no_color.nil?
    CocoapodsPodx::Runtime.singleton_class.define_method(:install_table_color_enabled?) { original_color_enabled.call } if original_color_enabled
  end

  def test_pod_install_runtime_color_can_be_enabled_by_shim_env
    previous_color = ENV['COCOAPODS_PODX_COLOR']
    previous_no_color = ENV['NO_COLOR']
    ENV['COCOAPODS_PODX_COLOR'] = '1'
    ENV.delete('NO_COLOR')

    local = CocoapodsPodx::Runtime.send(:color_install_table_value, '本地', '本地')

    assert_includes local, "\e[36m"
  ensure
    ENV['COCOAPODS_PODX_COLOR'] = previous_color if previous_color
    ENV.delete('COCOAPODS_PODX_COLOR') if previous_color.nil?
    ENV['NO_COLOR'] = previous_no_color if previous_no_color
    ENV.delete('NO_COLOR') if previous_no_color.nil?
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

  def test_dependency_report_shows_managed_branches_versions_and_dependencies
    File.write(File.join(@project_dir, 'Podfile.lock'), <<~YAML)
      PODS:
        - NNApperance (0.1.0):
          - Masonry
        - NNLogin (0.1.0):
          - NNApperance
          - Alamofire
        - Alamofire (5.8.0)
        - Masonry (1.1.0)
      DEPENDENCIES:
        - NNApperance
        - NNLogin
        - Alamofire
      EXTERNAL SOURCES:
        NNApperance:
          :git: http://git.example.com/nn_ios/nnapperance.git
    YAML
    helper = Class.new do
      include CocoapodsPodx::Commands::DependencyReport

      def initialize(project_directory)
        @project_directory = project_directory
      end

      def project_directory
        @project_directory
      end
    end.new(@project_dir)

    rows = helper.build_dependency_report_rows

    assert_includes rows, ['NNApperance', '内部组件', 'develop', 'Masonry']
    assert_includes rows, ['NNLogin', '内部组件', 'develop', 'NNApperance, Alamofire']
    assert_includes rows, ['Alamofire', '三方库', '5.8.0', '-']
    summary_rows = helper.dependency_summary_rows(rows)
    assert_includes summary_rows, ['NNLogin', '内部组件', 'develop', '2']
    assert_operator summary_rows.index(['NNLogin', '内部组件', 'develop', '2']), :<, summary_rows.index(['Alamofire', '三方库', '5.8.0', '0'])
    assert_includes helper.dependency_relation_rows(rows), ['NNLogin', 'NNApperance, Alamofire']
    assert_equal ['NNApperance', 'NNLogin'], helper.dependency_relation_groups(rows).map { |group| group[:name] }
  end

  def test_skill_runtime_lists_and_verifies_shallow_skills
    File.write(File.join(@project_dir, 'Podfile.lock'), "PODS:\n  - Alamofire (5.8.0)\n")
    helper = Class.new do
      include CocoapodsPodx::Commands::SkillRuntime

      def initialize(project_directory)
        @project_directory = project_directory
        @publish_branch = 'release/5.14.2'
      end

      def project_directory
        @project_directory
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def config_path
        File.join(@project_directory, 'podx.config.yml')
      end

      def main_app_branch
        'develop'
      end

      def selected_jenkins_job_url
        'http://jenkins.example.com/job/nn/'
      end
    end.new(@project_dir)

    skill_names = helper.podx_skill_definitions.map { |skill| skill[:name] }
    rows = helper.podx_skill_verify_rows(helper.find_podx_skill!('release_testflight'))

    assert_includes skill_names, 'dependency_audit'
    assert_includes skill_names, 'release_testflight'
    assert_equal '发布', helper.find_podx_skill!('release_testflight')[:stage]
    assert_equal ['release_pgyer', 'release_testflight', 'release_appstore'], helper.filter_podx_skills(helper.podx_skill_definitions, '发布').map { |skill| skill[:name] }
    assert_includes rows, ['release分支', 'ok', 'release/5.14.2']
  end

  def test_skill_runtime_rejects_testflight_without_release_branch
    helper = Class.new do
      include CocoapodsPodx::Commands::SkillRuntime

      def initialize(project_directory)
        @project_directory = project_directory
      end

      def project_directory
        @project_directory
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def config_path
        File.join(@project_directory, 'podx.config.yml')
      end

      def main_app_branch
        'develop'
      end

      def selected_jenkins_job_url
        'http://jenkins.example.com/job/nn/'
      end
    end.new(@project_dir)

    rows = helper.podx_skill_verify_rows(helper.find_podx_skill!('release_testflight'))

    assert_includes rows, ['release分支', 'fail', 'tf/app 仅允许 release/x.x.x；可使用 --branch release/x.x.x']
  end

  def test_skill_runtime_loads_project_skill_library
    FileUtils.mkdir_p(File.join(@project_dir, '.podx'))
    File.write(File.join(@project_dir, '.podx', 'skills.yml'), <<~YAML)
      skills:
        - name: local_dependency_audit
          scene: 本地依赖巡检
          steps:
            - podx deps
            - podx doctor
    YAML
    helper = Class.new do
      include CocoapodsPodx::Commands::SkillRuntime

      def initialize(project_directory)
        @project_directory = project_directory
      end

      def project_directory
        @project_directory
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def config_path
        File.join(@project_directory, 'podx.config.yml')
      end
    end.new(@project_dir)

    skill = helper.find_podx_skill!('local_dependency_audit')
    rows = helper.podx_skill_verify_rows(skill)

    assert_equal '项目', skill[:source]
    assert_equal '项目', skill[:stage]
    assert_equal ['podx deps', 'podx doctor'], skill[:steps]
    assert_includes rows, ['steps', 'ok', '2 个步骤']
  end

  def test_skill_runtime_supports_composed_project_skills
    FileUtils.mkdir_p(File.join(@project_dir, '.podx'))
    File.write(File.join(@project_dir, '.podx', 'skills.yml'), <<~YAML)
      skills:
        - name: local_dependency_audit
          stage: 依赖治理
          scene: 本地依赖巡检
          steps:
            - podx deps
        - name: local_release_readiness
          stage: 发布
          scene: 发布准备度检查
          depends_on:
            - local_dependency_audit
          steps:
            - mgit status
    YAML
    helper = Class.new do
      include CocoapodsPodx::Commands::SkillRuntime

      def initialize(project_directory)
        @project_directory = project_directory
      end

      def project_directory
        @project_directory
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def config_path
        File.join(@project_directory, 'podx.config.yml')
      end
    end.new(@project_dir)

    skill = helper.find_podx_skill!('local_release_readiness')
    rows = helper.podx_skill_verify_rows(skill)

    assert_equal ['local_dependency_audit'], skill[:depends_on]
    assert_equal 'local_dependency_audit', helper.podx_skill_depends_text(skill)
    assert_includes rows, ['depends_on:local_dependency_audit', 'ok', 'local_dependency_audit']
    assert_includes helper.podx_skill_graph_rows, ['local_release_readiness', '发布', 'local_dependency_audit']
  end

  def test_skill_runtime_plans_composed_project_skills
    FileUtils.mkdir_p(File.join(@project_dir, '.podx'))
    File.write(File.join(@project_dir, '.podx', 'skills.yml'), <<~YAML)
      skills:
        - name: local_dependency_audit
          stage: 依赖治理
          scene: 本地依赖巡检
          steps:
            - podx deps
            - podx doctor
        - name: local_publish_precheck
          stage: 发布
          scene: 发布前巡检
          steps:
            - mgit status
        - name: local_release_readiness
          stage: 发布
          scene: 发布准备度检查
          depends_on:
            - local_dependency_audit
            - local_publish_precheck
    YAML
    helper = Class.new do
      include CocoapodsPodx::Commands::SkillRuntime

      def initialize(project_directory)
        @project_directory = project_directory
      end

      def project_directory
        @project_directory
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def config_path
        File.join(@project_directory, 'podx.config.yml')
      end
    end.new(@project_dir)

    rows = helper.podx_skill_plan_rows(helper.find_podx_skill!('local_release_readiness'))

    assert_equal [1, 'local_dependency_audit', '步骤', 'podx deps'], rows[0]
    assert_equal [2, 'local_dependency_audit', '步骤', 'podx doctor'], rows[1]
    assert_equal [3, 'local_publish_precheck', '步骤', 'mgit status'], rows[2]
    assert_equal [4, 'local_release_readiness', '入口', '-'], rows[3]
  end

  def test_skill_runtime_plan_rejects_unsupported_project_step
    FileUtils.mkdir_p(File.join(@project_dir, '.podx'))
    File.write(File.join(@project_dir, '.podx', 'skills.yml'), <<~YAML)
      skills:
        - name: unsafe_plan
          steps:
            - ruby dangerous.rb
    YAML
    helper = Class.new do
      include CocoapodsPodx::Commands::SkillRuntime

      def initialize(project_directory)
        @project_directory = project_directory
      end

      def project_directory
        @project_directory
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def config_path
        File.join(@project_directory, 'podx.config.yml')
      end
    end.new(@project_dir)

    error = assert_raises(Pod::Informative) do
      helper.validate_podx_skill_plan!(helper.find_podx_skill!('unsafe_plan'))
    end
    assert_includes error.message, '不支持的命令：ruby dangerous.rb'
  end

  def test_skill_runtime_lints_project_skill_library
    FileUtils.mkdir_p(File.join(@project_dir, '.podx'))
    File.write(File.join(@project_dir, '.podx', 'skills.yml'), <<~YAML)
      skills:
        - name: local_dependency_audit
          stage: 依赖治理
          scene: 本地依赖巡检
          steps:
            - podx deps
        - name: local_release_readiness
          stage: 发布
          scene: 发布准备度检查
          depends_on:
            - local_dependency_audit
    YAML
    helper = Class.new do
      include CocoapodsPodx::Commands::SkillRuntime

      def initialize(project_directory)
        @project_directory = project_directory
      end

      def project_directory
        @project_directory
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def config_path
        File.join(@project_directory, 'podx.config.yml')
      end
    end.new(@project_dir)

    rows = helper.podx_skill_lint_rows

    assert_includes rows, ['name', 'ok', '8 个 skill 名称唯一']
    assert_includes rows, ['steps', 'ok', '由 depends_on 编排']
    assert_includes rows, ['project_file', 'ok', File.join(@project_dir, '.podx', 'skills.yml')]
  end

  def test_skill_runtime_lint_rejects_duplicate_names
    FileUtils.mkdir_p(File.join(@project_dir, '.podx'))
    File.write(File.join(@project_dir, '.podx', 'skills.yml'), <<~YAML)
      skills:
        - name: dependency_audit
          scene: 重名技能
          steps:
            - podx deps
    YAML
    helper = Class.new do
      include CocoapodsPodx::Commands::SkillRuntime

      def initialize(project_directory)
        @project_directory = project_directory
      end

      def project_directory
        @project_directory
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def config_path
        File.join(@project_directory, 'podx.config.yml')
      end

      def print_box_table(_title, _headers, _rows); end
    end.new(@project_dir)

    rows = helper.podx_skill_lint_rows
    error = assert_raises(Pod::Informative) { helper.lint_podx_skills }

    assert_includes rows, ['name', 'fail', 'skill 名称重复：dependency_audit']
    assert_includes error.message, 'skill library lint 失败'
  end

  def test_skill_runtime_rejects_unknown_skill_dependency
    FileUtils.mkdir_p(File.join(@project_dir, '.podx'))
    File.write(File.join(@project_dir, '.podx', 'skills.yml'), <<~YAML)
      skills:
        - name: bad_composed_skill
          depends_on:
            - missing_skill
          steps:
            - podx deps
    YAML
    helper = Class.new do
      include CocoapodsPodx::Commands::SkillRuntime

      def initialize(project_directory)
        @project_directory = project_directory
      end

      def project_directory
        @project_directory
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def config_path
        File.join(@project_directory, 'podx.config.yml')
      end
    end.new(@project_dir)

    rows = helper.podx_skill_verify_rows(helper.find_podx_skill!('bad_composed_skill'))

    assert_includes rows, ['depends_on:missing_skill', 'fail', '未知依赖 skill：missing_skill']
  end

  def test_skill_runtime_rejects_circular_skill_dependency
    FileUtils.mkdir_p(File.join(@project_dir, '.podx'))
    File.write(File.join(@project_dir, '.podx', 'skills.yml'), <<~YAML)
      skills:
        - name: skill_a
          depends_on:
            - skill_b
          steps:
            - podx deps
        - name: skill_b
          depends_on:
            - skill_a
          steps:
            - podx doctor
    YAML
    helper = Class.new do
      include CocoapodsPodx::Commands::SkillRuntime

      def initialize(project_directory)
        @project_directory = project_directory
      end

      def project_directory
        @project_directory
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def config_path
        File.join(@project_directory, 'podx.config.yml')
      end
    end.new(@project_dir)

    rows = helper.podx_skill_verify_rows(helper.find_podx_skill!('skill_a'))

    assert_includes rows, ['depends_on', 'fail', '检测到循环依赖：skill_a -> skill_b -> skill_a']
  end

  def test_skill_runtime_doctor_reports_skill_availability
    helper = Class.new do
      include CocoapodsPodx::Commands::SkillRuntime

      def initialize(project_directory)
        @project_directory = project_directory
      end

      def project_directory
        @project_directory
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def config_path
        File.join(@project_directory, 'podx.config.yml')
      end

      def main_app_branch
        'develop'
      end

      def selected_jenkins_job_url
        'http://jenkins.example.com/job/nn/'
      end
    end.new(@project_dir)

    File.write(File.join(@project_dir, 'Podfile.lock'), "PODS:\n  - Alamofire (5.8.0)\n")
    rows = helper.podx_skill_doctor_rows

    assert_includes rows, ['dependency_audit', '内置', '可用', '前置条件通过']
    assert_includes rows, ['release_testflight', '内置', '不可用', 'release分支: tf/app 仅允许 release/x.x.x；可使用 --branch release/x.x.x']
  end

  def test_skill_runtime_rejects_unsupported_project_skill_step
    FileUtils.mkdir_p(File.join(@project_dir, '.podx'))
    File.write(File.join(@project_dir, '.podx', 'skills.yml'), <<~YAML)
      skills:
        - name: unsafe_step
          scene: 非法步骤
          steps:
            - ruby dangerous.rb
    YAML
    helper = Class.new do
      include CocoapodsPodx::Commands::SkillRuntime

      def initialize(project_directory)
        @project_directory = project_directory
      end

      def project_directory
        @project_directory
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def config_path
        File.join(@project_directory, 'podx.config.yml')
      end
    end.new(@project_dir)

    rows = helper.podx_skill_verify_rows(helper.find_podx_skill!('unsafe_step'))

    assert_includes rows, ['step1', 'fail', '不支持的命令：ruby dangerous.rb']
  end

  def test_default_skill_library_contains_publish_precheck
    helper = Class.new do
      include CocoapodsPodx::Commands::SkillRuntime

      def initialize(project_directory)
        @project_directory = project_directory
      end

      def project_directory
        @project_directory
      end
    end.new(@project_dir)

    assert_includes helper.default_podx_skill_library, 'local_publish_precheck'
    assert_includes helper.default_podx_skill_library, 'stage: 发布'
    assert_includes helper.default_podx_skill_library, 'local_release_readiness'
    assert_includes helper.default_podx_skill_library, 'depends_on:'
    assert_includes helper.default_podx_skill_library, 'mgit status'
  end

  def test_skill_runtime_records_successful_runs
    File.write(File.join(@project_dir, 'Podfile.lock'), "PODS:\n  - Alamofire (5.8.0)\n")
    helper = Class.new do
      include CocoapodsPodx::Commands::SkillRuntime

      def initialize(project_directory)
        @project_directory = project_directory
      end

      def project_directory
        @project_directory
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def config_path
        File.join(@project_directory, 'podx.config.yml')
      end

      def show_dependency_report; end

      def doctor_overlay(_entries); end

      def print_box_table(_title, _headers, _rows); end
    end.new(@project_dir)

    helper.run_podx_skill('dependency_audit', [])
    history = helper.load_podx_skill_history

    assert_equal 1, history.size
    assert_equal 'dependency_audit', history.first['skill']
    assert_equal 'success', history.first['status']
    assert_equal '完成', history.first['detail']
  end

  def test_skill_runtime_summarizes_run_stats
    FileUtils.mkdir_p(File.join(@project_dir, '.podx'))
    File.write(File.join(@project_dir, '.podx', 'skill_runs.yml'), {
      'runs' => [
        {
          'skill' => 'dependency_audit',
          'source' => '内置',
          'status' => 'success',
          'started_at' => '2026-05-27T10:00:00+08:00',
          'duration' => '1.00s',
          'detail' => '完成'
        },
        {
          'skill' => 'dependency_audit',
          'source' => '内置',
          'status' => 'failed',
          'started_at' => '2026-05-27T11:00:00+08:00',
          'duration' => '0.20s',
          'detail' => '失败'
        },
        {
          'skill' => 'release_pgyer',
          'source' => '内置',
          'status' => 'success',
          'started_at' => '2026-05-27T12:00:00+08:00',
          'duration' => '2.00s',
          'detail' => '完成'
        }
      ]
    }.to_yaml)
    helper = Class.new do
      include CocoapodsPodx::Commands::SkillRuntime

      def initialize(project_directory)
        @project_directory = project_directory
      end

      def project_directory
        @project_directory
      end
    end.new(@project_dir)

    rows = helper.podx_skill_stats_rows

    assert_includes rows, ['dependency_audit', 2, 1, 1, '50%', 'failed', '2026-05-27T11:00:00+08:00']
    assert_includes rows, ['release_pgyer', 1, 1, 0, '100%', 'success', '2026-05-27T12:00:00+08:00']
  end

  def test_skill_runtime_stats_are_empty_without_history
    helper = Class.new do
      include CocoapodsPodx::Commands::SkillRuntime

      def initialize(project_directory)
        @project_directory = project_directory
      end

      def project_directory
        @project_directory
      end
    end.new(@project_dir)

    assert_equal [], helper.podx_skill_stats_rows
  end

  def test_skill_runtime_reports_governance_summary
    FileUtils.mkdir_p(File.join(@project_dir, '.podx'))
    File.write(File.join(@project_dir, '.podx', 'skills.yml'), <<~YAML)
      skills:
        - name: local_dependency_audit
          stage: 依赖治理
          scene: 本地依赖巡检
          steps:
            - podx deps
    YAML
    File.write(File.join(@project_dir, '.podx', 'skill_runs.yml'), {
      'runs' => [
        {
          'skill' => 'local_dependency_audit',
          'source' => '项目',
          'status' => 'success',
          'started_at' => '2026-05-27T10:00:00+08:00',
          'duration' => '1.00s',
          'detail' => '完成'
        },
        {
          'skill' => 'local_dependency_audit',
          'source' => '项目',
          'status' => 'failed',
          'started_at' => '2026-05-27T11:00:00+08:00',
          'duration' => '1.00s',
          'detail' => '失败'
        }
      ]
    }.to_yaml)
    helper = Class.new do
      include CocoapodsPodx::Commands::SkillRuntime

      def initialize(project_directory)
        @project_directory = project_directory
      end

      def project_directory
        @project_directory
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def config_path
        File.join(@project_directory, 'podx.config.yml')
      end

      def main_app_branch
        'release/5.14.2'
      end

      def selected_jenkins_job_url
        'http://jenkins.example.com/job/nn/'
      end
    end.new(@project_dir)

    rows = helper.podx_skill_report_rows

    assert_includes rows, ['技能数量', 'ok', '7 个']
    assert_includes rows, ['项目技能库', 'ok', File.join(@project_dir, '.podx', 'skills.yml')]
    assert_includes rows, ['运行历史', 'ok', '2 次']
    assert_includes rows, ['总体成功率', 'ok', '50% (1/2)']
  end

  def test_skill_runtime_report_fails_on_lint_failure
    FileUtils.mkdir_p(File.join(@project_dir, '.podx'))
    File.write(File.join(@project_dir, '.podx', 'skills.yml'), <<~YAML)
      skills:
        - name: dependency_audit
          scene: 重名技能
          steps:
            - podx deps
    YAML
    helper = Class.new do
      include CocoapodsPodx::Commands::SkillRuntime

      def initialize(project_directory)
        @project_directory = project_directory
      end

      def project_directory
        @project_directory
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def config_path
        File.join(@project_directory, 'podx.config.yml')
      end

      def print_box_table(_title, _headers, _rows); end
    end.new(@project_dir)

    error = assert_raises(Pod::Informative) { helper.report_podx_skills }

    assert_includes error.message, 'skill report 检测到 lint 失败'
  end

  def test_skill_runtime_suggests_next_actions_without_project_skill_file
    helper = Class.new do
      include CocoapodsPodx::Commands::SkillRuntime

      def initialize(project_directory)
        @project_directory = project_directory
      end

      def project_directory
        @project_directory
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def config_path
        File.join(@project_directory, 'podx.config.yml')
      end

      def main_app_branch
        'develop'
      end

      def selected_jenkins_job_url
        'http://jenkins.example.com/job/nn/'
      end
    end.new(@project_dir)

    rows = helper.podx_skill_suggestion_rows

    assert_includes rows, ['初始化项目技能库', 'podx skill init', '生成 .podx/skills.yml，开始沉淀团队流程']
    assert_includes rows, ['建立运行基线', 'podx skill run dependency_audit', '暂无技能运行历史，建议先跑一次依赖巡检']
  end

  def test_skill_runtime_suggests_review_when_success_rate_is_low
    FileUtils.mkdir_p(File.join(@project_dir, '.podx'))
    File.write(File.join(@project_dir, '.podx', 'skills.yml'), <<~YAML)
      skills:
        - name: local_dependency_audit
          stage: 依赖治理
          scene: 本地依赖巡检
          steps:
            - podx deps
    YAML
    File.write(File.join(@project_dir, '.podx', 'skill_runs.yml'), {
      'runs' => [
        { 'skill' => 'local_dependency_audit', 'status' => 'success', 'started_at' => '2026-05-27T10:00:00+08:00' },
        { 'skill' => 'local_dependency_audit', 'status' => 'failed', 'started_at' => '2026-05-27T11:00:00+08:00' },
        { 'skill' => 'local_dependency_audit', 'status' => 'failed', 'started_at' => '2026-05-27T12:00:00+08:00' }
      ]
    }.to_yaml)
    helper = Class.new do
      include CocoapodsPodx::Commands::SkillRuntime

      def initialize(project_directory)
        @project_directory = project_directory
      end

      def project_directory
        @project_directory
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def config_path
        File.join(@project_directory, 'podx.config.yml')
      end

      def main_app_branch
        'release/5.14.2'
      end

      def selected_jenkins_job_url
        'http://jenkins.example.com/job/nn/'
      end
    end.new(@project_dir)

    rows = helper.podx_skill_suggestion_rows

    assert_includes rows, ['复盘失败技能', 'podx skill history 20', '总体成功率 33% (1/3)，建议沉淀修复经验']
  end

  def test_skill_runtime_builds_markdown_snapshot
    FileUtils.mkdir_p(File.join(@project_dir, '.podx'))
    File.write(File.join(@project_dir, '.podx', 'skills.yml'), <<~YAML)
      skills:
        - name: local_dependency_audit
          stage: 依赖治理
          scene: 本地依赖巡检
          steps:
            - podx deps
    YAML
    helper = Class.new do
      include CocoapodsPodx::Commands::SkillRuntime

      def initialize(project_directory)
        @project_directory = project_directory
      end

      def project_directory
        @project_directory
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def config_path
        File.join(@project_directory, 'podx.config.yml')
      end

      def main_app_branch
        'release/5.14.2'
      end

      def selected_jenkins_job_url
        'http://jenkins.example.com/job/nn/'
      end
    end.new(@project_dir)

    markdown = helper.podx_skill_snapshot_markdown

    assert_includes markdown, '# podx skill snapshot'
    assert_includes markdown, '## Governance Report'
    assert_includes markdown, '## Suggestions'
    assert_includes markdown, '## Lint'
    assert_includes markdown, '## Skill Catalog'
    assert_includes markdown, '| Skill | 来源 | 阶段 | 场景 | 依赖 | 入口 | 验证 |'
    assert_includes markdown, 'local_dependency_audit'
  end

  def test_skill_runtime_writes_markdown_snapshot
    helper = Class.new do
      include CocoapodsPodx::Commands::SkillRuntime

      def initialize(project_directory)
        @project_directory = project_directory
      end

      def project_directory
        @project_directory
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def config_path
        File.join(@project_directory, 'podx.config.yml')
      end

      def print_box_table(_title, _headers, _rows); end
    end.new(@project_dir)

    helper.snapshot_podx_skills
    path = File.join(@project_dir, '.podx', 'skill_snapshot.md')

    assert File.exist?(path)
    assert_includes File.read(path), '# podx skill snapshot'
  end

  def test_skill_runtime_ci_rows_include_lint_report_and_snapshot
    FileUtils.mkdir_p(File.join(@project_dir, '.podx'))
    File.write(File.join(@project_dir, 'Podfile.lock'), "PODS:\n  - Alamofire (5.8.0)\n")
    File.write(File.join(@project_dir, '.podx', 'skills.yml'), <<~YAML)
      skills:
        - name: local_dependency_audit
          stage: 依赖治理
          scene: 本地依赖巡检
          steps:
            - podx deps
    YAML
    helper = Class.new do
      include CocoapodsPodx::Commands::SkillRuntime

      def initialize(project_directory)
        @project_directory = project_directory
      end

      def project_directory
        @project_directory
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def config_path
        File.join(@project_directory, 'podx.config.yml')
      end

      def main_app_branch
        'release/5.14.2'
      end

      def selected_jenkins_job_url
        'http://jenkins.example.com/job/nn/'
      end
    end.new(@project_dir)

    rows = helper.podx_skill_ci_rows

    assert_includes rows, ['mode', 'ok', 'default']
    assert_includes rows, ['lint', 'ok', 'fail 0, warn 0']
    assert_includes rows, ['report', 'warn', '6 项']
    assert_includes rows, ['snapshot', 'ok', File.join(@project_dir, '.podx', 'skill_snapshot.md')]
  end

  def test_skill_runtime_ci_writes_snapshot_before_failing_on_lint_error
    FileUtils.mkdir_p(File.join(@project_dir, '.podx'))
    File.write(File.join(@project_dir, '.podx', 'skills.yml'), <<~YAML)
      skills:
        - name: dependency_audit
          scene: 重名技能
          steps:
            - podx deps
    YAML
    helper = Class.new do
      include CocoapodsPodx::Commands::SkillRuntime

      def initialize(project_directory)
        @project_directory = project_directory
      end

      def project_directory
        @project_directory
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def config_path
        File.join(@project_directory, 'podx.config.yml')
      end

      def print_box_table(_title, _headers, _rows); end
    end.new(@project_dir)

    error = assert_raises(Pod::Informative) { helper.ci_podx_skills }
    path = File.join(@project_dir, '.podx', 'skill_snapshot.md')

    assert_includes error.message, 'skill ci 检测失败'
    assert File.exist?(path)
    assert File.exist?(File.join(@project_dir, '.podx', 'skill_ci.json'))
    assert_includes File.read(path), 'skill 名称重复：dependency_audit'
  end

  def test_skill_runtime_ci_writes_machine_readable_json_report
    FileUtils.mkdir_p(File.join(@project_dir, '.podx'))
    File.write(File.join(@project_dir, 'Podfile.lock'), "PODS:\n  - Alamofire (5.8.0)\n")
    File.write(File.join(@project_dir, '.podx', 'skills.yml'), <<~YAML)
      skills:
        - name: local_dependency_audit
          stage: 依赖治理
          scene: 本地依赖巡检
          steps:
            - podx deps
    YAML
    helper = Class.new do
      include CocoapodsPodx::Commands::SkillRuntime

      def initialize(project_directory)
        @project_directory = project_directory
      end

      def project_directory
        @project_directory
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def config_path
        File.join(@project_directory, 'podx.config.yml')
      end

      def main_app_branch
        'release/5.14.2'
      end

      def selected_jenkins_job_url
        'http://jenkins.example.com/job/nn/'
      end

      def print_box_table(_title, _headers, _rows); end
    end.new(@project_dir)

    helper.ci_podx_skills
    payload = JSON.parse(File.read(File.join(@project_dir, '.podx', 'skill_ci.json')))

    assert_equal @project_dir, payload['project']
    assert_equal File.join(@project_dir, '.podx', 'skill_snapshot.md'), payload['snapshot_path']
    assert_equal File.join(@project_dir, '.podx', 'skill_ci.json'), payload['json_path']
    assert_equal false, payload['strict']
    assert_equal 'warn', payload['status']
    assert_includes payload['summary'], { 'step' => 'mode', 'status' => 'ok', 'detail' => 'default' }
    assert_includes payload['summary'], { 'step' => 'lint', 'status' => 'ok', 'detail' => 'fail 0, warn 0' }
    assert payload['lint'].any? { |row| row['rule'] == 'name' && row['status'] == 'ok' }
    assert payload['skills'].any? { |row| row['name'] == 'local_dependency_audit' && row['source'] == '项目' }
  end

  def test_skill_runtime_ci_strict_fails_on_report_failure
    helper = Class.new do
      include CocoapodsPodx::Commands::SkillRuntime

      def initialize(project_directory)
        @project_directory = project_directory
      end

      def project_directory
        @project_directory
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def config_path
        File.join(@project_directory, 'podx.config.yml')
      end

      def print_box_table(_title, _headers, _rows); end
    end.new(@project_dir)

    error = assert_raises(Pod::Informative) { helper.ci_podx_skills('strict') }
    payload = JSON.parse(File.read(File.join(@project_dir, '.podx', 'skill_ci.json')))

    assert_includes error.message, 'skill ci strict 检测失败'
    assert_equal true, payload['strict']
    assert_equal 'fail', payload['status']
    assert_includes payload['summary'], { 'step' => 'mode', 'status' => 'ok', 'detail' => 'strict' }
  end

  def test_skill_runtime_ci_rejects_unknown_mode
    helper = Class.new do
      include CocoapodsPodx::Commands::SkillRuntime

      def initialize(project_directory)
        @project_directory = project_directory
      end

      def project_directory
        @project_directory
      end
    end.new(@project_dir)

    error = assert_raises(Pod::Informative) { helper.ci_podx_skills('loud') }

    assert_includes error.message, '未知 skill ci 模式'
  end

  def test_skill_runtime_does_not_record_dry_run
    File.write(File.join(@project_dir, 'Podfile.lock'), "PODS:\n  - Alamofire (5.8.0)\n")
    helper = Class.new do
      include CocoapodsPodx::Commands::SkillRuntime

      def initialize(project_directory)
        @project_directory = project_directory
        @dry_run = true
      end

      def project_directory
        @project_directory
      end

      def podfile_path
        File.join(@project_directory, 'Podfile')
      end

      def config_path
        File.join(@project_directory, 'podx.config.yml')
      end

      def show_dependency_report; end

      def doctor_overlay(_entries); end

      def print_box_table(_title, _headers, _rows); end
    end.new(@project_dir)

    helper.run_podx_skill('dependency_audit', [])

    refute File.exist?(File.join(@project_dir, '.podx', 'skill_runs.yml'))
  end

  def test_project_config_exposes_publish_settings
    config = CocoapodsPodx::Runtime.config

    assert_equal '.mgit-publish', config[:publish_work_dir]
    assert_equal 'develop', config[:publish_base_branch]
    assert_equal false, config[:publish_pipeline_gate]
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
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx workon NNBussCom'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx ship [pgyer|tf|app]'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx tools'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx install --repo-update'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx clean NNRtc'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx cache clean NNRtc'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'cache)'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'run_pod_overlay --clean "$@"'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'run_pod_install_with_auto_fix "$@"'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'cleanup_overlay_pods_dir'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'sync_graph_after_pod_install'
    assert_includes CocoapodsPodx::ShimGenerator.podx, '.claude/mcps/update-codegraph.sh'
    refute_includes CocoapodsPodx::ShimGenerator.podx, '【podx install】同步图谱索引规则'
    assert_includes CocoapodsPodx::ShimGenerator.podx, '/bin/sh "$graph_script" >/dev/null 2>&1'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'overlay_pod_names'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'Podfile.overlay'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'group_name_from_pod_line'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'overlay_names.include?(group_name)'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'Pods/$pod_name'
    assert_includes CocoapodsPodx::ShimGenerator.podx, '已清理 Pods 旧本地组件'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'Verification checksum was incorrect'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'run_raw_pod_install_capture "$retry_log_file" --repo-update "$@"'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'COCOAPODS_PODX_REMOTE_UPDATES_FILE'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'COCOAPODS_PODX_REPO_UPDATE=1'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'run_pod_update_for_remote_updates'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'pod update $pod_names --repo-update'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'snapshot_pbxproj_files'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'restore_noop_pbxproj_changes "$pbxproj_snapshot_dir"'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'exceptions|inputPaths|outputPaths'
    refute_includes CocoapodsPodx::ShimGenerator.podx, '已还原 Xcode 工程无效修改'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'COCOAPODS_PODX_INSTALL_VERBOSE'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'print_pod_install_success_log "$log_file"'
    assert_includes CocoapodsPodx::ShimGenerator.podx, "sed -n '/^【podx install】/p;/^[+|]/p'"
    assert_includes CocoapodsPodx::ShimGenerator.podx, '【podx install】完成'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx cache clean ${pod_name:-NAME}'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'show_modern_cli_tools'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'workon|dev)'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'diagnose)'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'repair|heal)'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx upgrade [VERSION]'
    refute_includes CocoapodsPodx::ShimGenerator.podx, 'podx uninstall                 '
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx list'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx rules'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx rules check'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx rules sync'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx rules snapshot'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx rules ci'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx pipeline'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx pipeline flow'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx pipeline ci'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx pipeline script'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx pipeline doctor'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx pipeline snapshot'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx pipeline report'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx pipeline status'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx pipeline gate'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx pipeline policy'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx pipeline readiness'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx publish --pipeline-gate'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx publish --no-pipeline-gate'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx publish --no-wechat-notify'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx publish --force-private-pod-update'
    assert_includes CocoapodsPodx::ShimGenerator.podx, '--notify-wechat'
    assert_includes CocoapodsPodx::ShimGenerator.podx, '--force-private-pod-update'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'normalized << "--notify-wechat=false"'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'normalized << "--force-private-pod-update=true"'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'normalized << "--force-private-pod-update=false"'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'run_pod_overlay --clean'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'run_pod_overlay --rules'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'run_pod_overlay --pipeline'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx ai init'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx publish log [BUILD]'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx publish history [N]'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx publish doctor [BUILD]'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx publish fix [BUILD]'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx git-token status'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx git-token set'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx git-token clear'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx_git_token_command'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx_git_token_validate'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx_gitlab_url'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'git_base_url'
    assert_includes CocoapodsPodx::ShimGenerator.podx, "begin\ntoken = ENV.fetch"
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'validation_status=$?'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'print_podx_git_token_setup_guide'
    assert_includes CocoapodsPodx::ShimGenerator.podx, '请访问 ${gitlab_url%/}/profile/personal_access_tokens'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'Scopes 只勾选 api'
    assert_includes CocoapodsPodx::ShimGenerator.podx, '/api/v4/user'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'COCOAPODS_PODX_GIT_TOKEN [$source] 有效'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'security add-generic-password'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'load_podx_git_token_from_keychain'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx publish --branch=develop'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx publish tf --branch=release/x.x.x'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx publish app --branch=release/x.x.x'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'cocoapods_podx/publish_only'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx hooks install'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'podx skill ci'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'mgit branch [NAME]'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'mgit checkout [NAME] BRANCH'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'mgit checkout -b BRANCH'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'mgit merge [NAME] BRANCH'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'mgit stash [NAME]'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'mgit stash list [NAME]'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'mgit stash apply NAME'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'mgit diff [NAME]'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'mgit log [NAME]'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'mgit add [NAME]'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'mgit pull [NAME]'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'mgit pull --ff-only [NAME]'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'mgit rebase --continue'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'mgit rebase --abort'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'mgit commit [NAME] -m "msg"'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'run_pod_overlay --dry-run --hooks'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'detect_cocoapods_gem_home'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'detect_cocoapods_ruby'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'detect_podx_lib_path'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'pod_available'
    refute_includes CocoapodsPodx::ShimGenerator.podx, 'pod --version'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'version="$(ruby -e'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'normalized << "#{arg}=#{args.shift}"'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'latest_podx_version_from_nexus'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'upgrade_cocoapods_podx'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'cocoapods-podx [check] 正在查询远端最新版本'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'exec_upgrade_from_temp_shim'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'COCOAPODS_PODX_COMMAND_DIR'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'COCOAPODS_PODX_SELF_UPGRADE_DIR'
    assert_includes CocoapodsPodx::ShimGenerator.podx, '__upgrade)'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'install_upgrade_shim'
    assert_includes CocoapodsPodx::ShimGenerator.podx, '跳过正在执行的 shim 刷新'
    assert_includes CocoapodsPodx::ShimGenerator.podx, '版本号不合法'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'exit $?'
    refute_includes CocoapodsPodx::ShimGenerator.podx, 'cp "$installed_dir/bin/podx" "$command_dir/podx"'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'cocoapods-podx $current_version 已是最新版本，无需更新'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'GEM_HOME="$gem_home"'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'RUBYLIB="$podx_lib'
    refute_includes CocoapodsPodx::ShimGenerator.podx, 'pod podx --jenkins-fix'
    refute_includes CocoapodsPodx::ShimGenerator.podx, 'overlay --jenkins-fix'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'COCOAPODS_PODX_INTERNAL=1'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'COCOAPODS_PODX_COLOR'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'progress_first_output_seen'
    assert_includes CocoapodsPodx::ShimGenerator.podx, '[ "$progress_first_output_seen" -eq 0 ]'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'print_progress_log_chunk'
    assert_includes CocoapodsPodx::ShimGenerator.podx, 'Ignoring ffi-[^ ]* because its extensions are not built'
    refute_includes CocoapodsPodx::ShimGenerator.podx, 'branch|list)'
    refute_includes CocoapodsPodx::ShimGenerator.podx, '请使用 mgit branch'
    assert_includes CocoapodsPodx::ShimGenerator.mgit, 'mgit publish'
    assert_includes CocoapodsPodx::ShimGenerator.mgit, 'mgit_standalone'
    assert_includes CocoapodsPodx::ShimGenerator.mgit, 'detect_cocoapods_gem_home'
    assert_includes CocoapodsPodx::ShimGenerator.mgit, 'detect_podx_lib_path'
    assert_includes CocoapodsPodx::ShimGenerator.mgit, 'load_podx_git_token_from_keychain'
    assert_includes CocoapodsPodx::ShimGenerator.mgit, 'security find-generic-password'
    assert_includes CocoapodsPodx::ShimGenerator.mgit, 'progress_first_output_seen'
    assert_includes CocoapodsPodx::ShimGenerator.mgit, '[ "$progress_first_output_seen" -eq 0 ]'
    assert_includes CocoapodsPodx::ShimGenerator.mgit, 'print_progress_log_chunk'
    assert_includes CocoapodsPodx::ShimGenerator.mgit, 'Ignoring ffi-[^ ]* because its extensions are not built'
    assert_includes CocoapodsPodx::ShimGenerator.mgit, 'gem_home=""'
    assert_includes CocoapodsPodx::ShimGenerator.mgit, 'if [ -z "$podx_lib" ]; then'
    assert_includes CocoapodsPodx::ShimGenerator.mgit, 'RUBYLIB="$podx_lib'
    assert_includes CocoapodsPodx::ShimGenerator.mgit, 'COCOAPODS_PODX_COLOR'
    refute_includes CocoapodsPodx::ShimGenerator.mgit, 'pod podx'
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
    assert_includes File.read(File.join(ai_dir, '.gitignore')), '.mgit-publish/'
    assert_includes File.read(File.join(ai_dir, '.gitignore')), 'Development Pods/'
    assert_includes File.read(File.join(ai_dir, '.gitignore')), '.codegraphignore'
    assert_includes File.read(File.join(ai_dir, '.gitignore')), '.code-review-graphignore'
    assert_includes File.read(File.join(ai_dir, '.gitignore')), '.podx/codegraph_ignore'
    assert_includes File.read(File.join(ai_dir, '.gitignore')), '.podx/skill_runs.yml'
    assert_includes File.read(File.join(ai_dir, '.gitignore')), '.podx/skill_snapshot.md'
    assert_includes File.read(File.join(ai_dir, '.gitignore')), '.podx/skill_ci.json'
    assert_includes File.read(File.join(ai_dir, '.claude', 'mcps', 'codex-mcp.example.toml')), 'code-review-graph'
    assert_includes File.read(File.join(ai_dir, '.claude', 'mcps', 'claude-mcp.example.json')), 'code-review-graph'
    assert_includes File.read(File.join(ai_dir, '.claude', 'mcps', 'README.md')), 'Hermes'
    assert_includes File.read(File.join(ai_dir, '.claude', 'memory', 'README.md')), 'Hermes Memory'
  ensure
    FileUtils.rm_rf(ai_dir) if ai_dir
  end

  def test_ai_bootstrap_gitignore_appends_new_runtime_rules_to_existing_marker
    ai_dir = Dir.mktmpdir('cocoapods-podx-ai-existing-gitignore')
    File.write(File.join(ai_dir, '.gitignore'), <<~TEXT)
      # AI / MCP local runtime state
      .hermes
      .claude/memory/MEMORY.md
    TEXT

    CocoapodsPodx::AiBootstrap.ensure_gitignore(ai_dir)
    gitignore = File.read(File.join(ai_dir, '.gitignore'))

    assert_equal 1, gitignore.scan(/^\.hermes$/).size
    assert_includes gitignore, '.mgit-publish/'
    assert_includes gitignore, 'Development Pods/'
    assert_includes gitignore, '.codegraphignore'
    assert_includes gitignore, '.code-review-graphignore'
    assert_includes gitignore, '.podx/codegraph_ignore'
    assert_includes gitignore, '.podx/skill_runs.yml'
    assert_includes gitignore, '.podx/skill_snapshot.md'
    assert_includes gitignore, '.podx/skill_ci.json'
  ensure
    FileUtils.rm_rf(ai_dir) if ai_dir
  end

  def test_ai_bootstrap_codegraph_ignore_keeps_only_overlay_local_development_pods
    ai_dir = Dir.mktmpdir('cocoapods-podx-ai-codegraph-ignore')
    File.write(File.join(ai_dir, 'Podfile.overlay'), "pod 'NNBussCom'\n")
    File.write(File.join(ai_dir, 'Podfile'), <<~RUBY)
      pod 'NNLogin', :branch => 'develop', :group_name => 'NNBussCom'
      pod 'NNBasciCommon', :branch => 'develop'
    RUBY
    FileUtils.mkdir_p(File.join(ai_dir, 'Development Pods', 'nnbusscom'))
    FileUtils.mkdir_p(File.join(ai_dir, 'Development Pods', 'nnbascicommon'))

    CocoapodsPodx::AiBootstrap.init(ai_dir, force: false)
    script = File.join(ai_dir, '.claude', 'mcps', 'update-codegraph.sh')
    assert system({ 'CODE_REVIEW_GRAPH_BIN' => '/usr/bin/true' }, '/bin/sh', script)

    ignore = File.read(File.join(ai_dir, '.code-review-graphignore'))
    assert_includes ignore, 'Pods/NNBussCom/**'
    assert_includes ignore, 'Pods/NNLogin/**'
    assert_includes ignore, 'Development Pods/nnbascicommon/**'
    refute_includes ignore, 'Pods/NNBasciCommon/**'
    refute_includes ignore, 'Development Pods/nnbusscom/**'
  ensure
    FileUtils.rm_rf(ai_dir) if ai_dir
  end

  def test_ai_update_warns_once_when_code_review_graph_missing
    ai_dir = Dir.mktmpdir('cocoapods-podx-ai-codegraph-missing')
    home_dir = Dir.mktmpdir('cocoapods-podx-ai-home-missing')
    File.write(File.join(ai_dir, 'Podfile.overlay'), '')
    File.write(File.join(ai_dir, 'Podfile'), '')

    CocoapodsPodx::AiBootstrap.init(ai_dir, force: false)
    script = File.join(ai_dir, '.claude', 'mcps', 'update-codegraph.sh')
    missing_codegraph = File.join(ai_dir, 'missing-code-review-graph')
    output = IO.popen(
      {
        'HOME' => home_dir,
        'CODE_REVIEW_GRAPH_BIN' => missing_codegraph
      },
      ['/bin/sh', script],
      err: [:child, :out],
      &:read
    )

    assert_equal 1, output.scan('warning: 未找到 code-review-graph').size
    refute_includes output, 'CodeGraph runtime'
  ensure
    FileUtils.rm_rf(ai_dir) if ai_dir
    FileUtils.rm_rf(home_dir) if home_dir
  end

  def test_ai_update_finds_code_review_graph_in_user_python_bin
    ai_dir = Dir.mktmpdir('cocoapods-podx-ai-codegraph-python-bin')
    home_dir = Dir.mktmpdir('cocoapods-podx-ai-home')
    File.write(File.join(ai_dir, 'Podfile.overlay'), '')
    File.write(File.join(ai_dir, 'Podfile'), '')
    python_bin = File.join(home_dir, 'Library', 'Python', '3.14', 'bin')
    FileUtils.mkdir_p(python_bin)
    fake_codegraph = File.join(python_bin, 'code-review-graph')
    File.write(fake_codegraph, <<~SH)
      #!/bin/sh
      if [ "${1:-}" = "detect-changes" ]; then
        echo "Analyzed 3 changed file(s):"
        echo "  - 2 changed function(s)/class(es)"
        echo "  - 1 test gap(s)"
        echo "  - Overall risk score: 0.40"
      else
        echo "INFO: FTS index rebuilt: 100 rows indexed"
      fi
      exit 0
    SH
    FileUtils.chmod('+x', fake_codegraph)

    CocoapodsPodx::AiBootstrap.init(ai_dir, force: false)
    script = File.join(ai_dir, '.claude', 'mcps', 'update-codegraph.sh')
    output = IO.popen(
      {
        'HOME' => home_dir,
        'CODE_REVIEW_GRAPH_BIN' => File.join(ai_dir, 'missing-code-review-graph')
      },
      ['/bin/sh', script],
      err: [:child, :out],
      &:read
    )

    assert_includes output, '【CodeGraph】索引规则已同步'
    assert_includes output, '【CodeGraph】图谱已更新'
    assert_includes output, '【CodeGraph】影响检查：3 个文件，风险 0.40，测试缺口 1'
    assert_includes output, '【podx ai】完成'
    refute_includes output, 'warning: 未找到 code-review-graph'
    refute_includes output, 'INFO: FTS index rebuilt'
  ensure
    FileUtils.rm_rf(ai_dir) if ai_dir
    FileUtils.rm_rf(home_dir) if home_dir
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

  def test_print_jenkins_progress_log_prints_latest_progressive_line
    publisher = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      def apply_jenkins_auth(_request); end

      def request_jenkins(_uri, _request)
        response = Net::HTTPOK.new('1.1', '200', 'OK')
        response.instance_variable_set(:@read, true)
        response['X-Text-Size'] = '128'
        response.body = [
          'Building in workspace /Users/a1/.jenkins/workspace/nn',
          '▸ Compiling LoginLogic.swift',
          'Successfully uploaded package to App Store Connect'
        ].join("\n")
        response
      end
    end.new

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      offset = publisher.print_jenkins_progress_log('http://jenkins.example.com/job/nn/1/', 0)
      assert_equal 128, offset
    end

    assert_includes output, '【打包进度】Successfully uploaded package to App Store Connect'
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_print_jenkins_progress_log_does_not_repeat_same_line
    publisher = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      def apply_jenkins_auth(_request); end

      def request_jenkins(_uri, _request)
        response = Net::HTTPOK.new('1.1', '200', 'OK')
        response.instance_variable_set(:@read, true)
        response['X-Text-Size'] = '256'
        response.body = "▸ Compiling LoginLogic.swift\n"
        response
      end
    end.new

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      publisher.print_jenkins_progress_log('http://jenkins.example.com/job/nn/1/', 0)
      publisher.print_jenkins_progress_log('http://jenkins.example.com/job/nn/1/', 128)
    end

    assert_equal 1, output.scan('▸ Compiling LoginLogic.swift').length
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_publish_success_prints_final_publish_summary
    publisher = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      def jenkins_json(_uri)
        { 'building' => false, 'result' => 'SUCCESS', 'duration' => 8_000 }
      end

      def print_jenkins_progress_log(_build_url, offset)
        offset
      end

      def apply_jenkins_auth(_request); end

      def request_jenkins(_uri, _request)
        response = Net::HTTPOK.new('1.1', '200', 'OK')
        response.instance_variable_set(:@read, true)
        response.body = [
          '[12:00:00]: Successfully uploaded package to App Store Connect',
          '[INFO] 已同步 Extension CURRENT_PROJECT_VERSION: 1 → 514006',
          '[SUCCESS] 蒲公英版本: 5.14.6(build [3768](https://www.pgyer.com/iC0d))',
          'BUILD_DESCRIPTION=Pgyer, 3768'
        ].join("\n")
        response
      end
    end.new

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      publisher.wait_for_jenkins_build('http://jenkins.example.com/job/nn/1337/', 1337, '蒲公英')
    end

    assert_includes output, '【打包结果】成功 蒲公英 #1337'
    assert_includes output, '【发布结果】Jenkins构建号 #1337 | 发布渠道 蒲公英 | 渠道构建号 3768'
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_extract_jenkins_channel_build_number_prefers_platform_build
    helper = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish
    end.new

    lines = [
      '[INFO] 已同步 Extension CURRENT_PROJECT_VERSION: 1 → 514006',
      '[INFO] Build号: 514006',
      '[SUCCESS] 蒲公英版本: 5.14.6(build [3768](https://www.pgyer.com/iC0d))',
      'BUILD_DESCRIPTION=Pgyer, 3768'
    ]

    assert_equal '3768', helper.extract_jenkins_channel_build_number(lines)
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

  def test_publish_does_not_sync_local_overlay_repos_after_success
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

    assert_equal [], publisher.updates
    refute_includes output, '【本地组件同步】'
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_publish_pipeline_gate_blocks_jenkins_trigger_when_enabled
    publisher = Class.new do
      include CocoapodsPodx::Commands::GitActions
      include CocoapodsPodx::Commands::PipelineRuntime
      include CocoapodsPodx::Commands::JenkinsPublish

      attr_reader :triggered

      def initialize(project_dir)
        @project_directory = project_dir
        @pod_names = []
        @dry_run = false
        @publish_pipeline_gate = true
        @triggered = false
      end

      def project_directory
        @project_directory
      end

      def validate_jenkins_publish_context!; end

      def pipeline_status_rows
        [['规则门禁', '失败', File.join(project_directory, '.podx', 'rules_snapshot.json')]]
      end

      def jenkins_publish_job_profile
        { default_channel: 'tf' }
      end

      def jenkins_deploy_target(_channel)
        { name: 'TestFlight', value: 'TestFlight,', kind: :app }
      end

      def validate_jenkins_publish_target!(*); end

      def validate_jenkins_publish_branch!(*); end

      def jenkins_publish_branch
        'origin/release/5.14.3'
      end

      def trigger_jenkins_build_with_auto_fix_retry(*)
        @triggered = true
      end
    end.new(@project_dir)

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      error = assert_raises(Pod::Informative) { publisher.publish_to_jenkins }
      assert_includes error.message, '发布预检失败'
    end

    refute publisher.triggered
    assert_includes output, '【publish pipeline gate】'
    assert_includes output, '【发布预检】TestFlight 严格门禁 失败 1 个'
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_publish_pipeline_gate_warns_for_pgyer_and_continues
    publisher = Class.new do
      include CocoapodsPodx::Commands::GitActions
      include CocoapodsPodx::Commands::PipelineRuntime
      include CocoapodsPodx::Commands::JenkinsPublish

      attr_reader :triggered

      def initialize(project_dir)
        @project_directory = project_dir
        @pod_names = []
        @dry_run = false
        @publish_pipeline_gate = true
        @triggered = false
      end

      def project_directory
        @project_directory
      end

      def validate_jenkins_publish_context!; end

      def pipeline_status_rows
        [['规则门禁', '失败', File.join(project_directory, '.podx', 'rules_snapshot.json')]]
      end

      def jenkins_publish_job_profile
        { default_channel: 'pgyer' }
      end

      def jenkins_deploy_target(_channel)
        { name: '蒲公英', value: 'Pgyer,', kind: :app }
      end

      def validate_jenkins_publish_target!(*); end

      def validate_jenkins_publish_branch!(*); end

      def jenkins_publish_branch
        'origin/develop'
      end

      def print_publish_header(*); end

      def publish_git_rows(_branch)
        []
      end

      def print_publish_git_table(_rows); end

      def validate_publish_remote_release_branches!(*); end

      def jenkins_build_params(*)
        {}
      end

      def print_jenkins_progress(_message); end

      def trigger_jenkins_build_with_auto_fix_retry(*)
        @triggered = true
      end
    end.new(@project_dir)

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      publisher.publish_to_jenkins
    end

    assert publisher.triggered
    assert_includes output, '【发布预检】蒲公英 告警门禁 失败 1 个'
    assert_includes output, '【发布预检】告警模式，继续发布'
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_publish_pipeline_gate_can_be_skipped
    publisher = Class.new do
      include CocoapodsPodx::Commands::GitActions
      include CocoapodsPodx::Commands::PipelineRuntime
      include CocoapodsPodx::Commands::JenkinsPublish

      attr_reader :triggered

      def initialize(project_dir)
        @project_directory = project_dir
        @pod_names = []
        @dry_run = false
        @publish_pipeline_gate = true
        @skip_publish_pipeline_gate = true
        @triggered = false
      end

      def project_directory
        @project_directory
      end

      def validate_jenkins_publish_context!; end

      def jenkins_publish_job_profile
        { default_channel: 'pgyer' }
      end

      def jenkins_deploy_target(_channel)
        { name: '蒲公英', value: 'Pgyer,', kind: :app }
      end

      def validate_jenkins_publish_target!(*); end

      def validate_jenkins_publish_branch!(*); end

      def jenkins_publish_branch
        'origin/develop'
      end

      def print_publish_header(*); end

      def publish_git_rows(_branch)
        []
      end

      def print_publish_git_table(_rows); end

      def validate_publish_remote_release_branches!(*); end

      def jenkins_build_params(*)
        {}
      end

      def print_jenkins_progress(_message); end

      def trigger_jenkins_build_with_auto_fix_retry(*)
        @triggered = true
      end
    end.new(@project_dir)

    publisher.publish_to_jenkins

    assert publisher.triggered
  end

  def test_publish_lock_blocks_concurrent_publish_for_same_job
    publisher = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      attr_reader :triggered

      def initialize(project_dir)
        @project_directory = project_dir
        @pod_names = []
        @dry_run = false
        @triggered = false
      end

      def project_directory
        @project_directory
      end

      def validate_jenkins_publish_context!; end

      def jenkins_publish_job_profile
        { default_channel: 'pgyer', job_name: 'nn' }
      end

      def jenkins_deploy_target(_channel)
        { name: '蒲公英', value: 'Pgyer,', kind: :app }
      end

      def validate_jenkins_publish_target!(*); end

      def validate_jenkins_publish_branch!(*); end

      def jenkins_publish_branch
        'origin/develop'
      end

      def print_publish_header(*); end

      def publish_git_rows(_branch)
        []
      end

      def print_publish_git_table(_rows); end

      def validate_publish_remote_release_branches!(*); end

      def jenkins_build_params(*)
        {}
      end

      def print_jenkins_progress(_message); end

      def trigger_jenkins_build_with_auto_fix_retry(*)
        @triggered = true
      end
    end.new(@project_dir)

    lock_dir = File.join(@project_dir, '.podx', 'locks')
    FileUtils.mkdir_p(lock_dir)
    lock_path = File.join(lock_dir, 'publish-nn.lock')
    lock = File.open(lock_path, File::RDWR | File::CREAT, 0o644)
    lock.write("pid=123\njob=nn\nbranch=origin/develop\nchannels=pgyer\nstarted_at=2026-05-29 10:00:00\n")
    lock.flush
    lock.flock(File::LOCK_EX)

    error = assert_raises(Pod::Informative) { publisher.publish_to_jenkins }
    assert_includes error.message, '当前工程已有 podx publish 正在执行'
    assert_includes error.message, 'job nn'
    refute publisher.triggered
  ensure
    lock&.flock(File::LOCK_UN)
    lock&.close
  end

  def test_publish_lock_can_be_skipped_explicitly
    publisher = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      attr_reader :triggered

      def initialize(project_dir)
        @project_directory = project_dir
        @pod_names = []
        @dry_run = false
        @skip_publish_lock = true
        @triggered = false
      end

      def project_directory
        @project_directory
      end

      def validate_jenkins_publish_context!; end

      def jenkins_publish_job_profile
        { default_channel: 'pgyer', job_name: 'nn' }
      end

      def jenkins_deploy_target(_channel)
        { name: '蒲公英', value: 'Pgyer,', kind: :app }
      end

      def validate_jenkins_publish_target!(*); end

      def validate_jenkins_publish_branch!(*); end

      def jenkins_publish_branch
        'origin/develop'
      end

      def print_publish_header(*); end

      def publish_git_rows(_branch)
        []
      end

      def print_publish_git_table(_rows); end

      def validate_publish_remote_release_branches!(*); end

      def jenkins_build_params(*)
        {}
      end

      def print_jenkins_progress(_message); end

      def trigger_jenkins_build_with_auto_fix_retry(*)
        @triggered = true
      end
    end.new(@project_dir)

    lock_dir = File.join(@project_dir, '.podx', 'locks')
    FileUtils.mkdir_p(lock_dir)
    lock_path = File.join(lock_dir, 'publish-nn.lock')
    lock = File.open(lock_path, File::RDWR | File::CREAT, 0o644)
    lock.flock(File::LOCK_EX)

    publisher.publish_to_jenkins

    assert publisher.triggered
  ensure
    lock&.flock(File::LOCK_UN)
    lock&.close
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

    assert_includes output, 'Jenkins 地址不可用：http://jenkins.example.com/job/first/，切换备用'
    assert_includes output, 'Jenkins 地址不可用：http://jenkins.example.com/job/second/'
    refute_includes output, '切换备用：http://jenkins.example.com/job/first/'
    refute_includes output, 'failed http://jenkins.example.com/job/second/'
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_jenkins_progress_log_updates_offset_and_prints_latest_line
    publisher = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      def apply_jenkins_auth(_request); end

      def request_jenkins(_uri, _request)
        response = Net::HTTPOK.new('1.1', '200', 'OK')
        response['X-Text-Size'] = '321'
        response.instance_variable_set(:@read, true)
        response.body = [
          '[11:54:50]: Set Team id to: M4HNX7MUD2 for target: NNIM for build configuration: Debug',
          '$ xcodebuild -resolvePackageDependencies -workspace /Users/a1/.jenkins/workspace/nn/NNIM.xcworkspace',
          'ERROR: Failed to load AuthKey file.'
        ].join("\n")
        response
      end
    end.new

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      assert_equal 321, publisher.print_jenkins_progress_log('http://jenkins.example.com/job/nn/1/', 0)
    end

    assert_includes output, '【打包进度】ERROR: Failed to load AuthKey file.'
    refute_includes output, 'Set Team id to'
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

  def test_hermes_publish_evolution_records_failure_case_database
    dir = Dir.mktmpdir('cocoapods-podx-cases')
    db_path = File.join(dir, 'cases.jsonl')
    original_db = ENV['COCOAPODS_PODX_FAILURE_CASE_DB']
    ENV['COCOAPODS_PODX_FAILURE_CASE_DB'] = db_path

    helper = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      def initialize
        @jenkins_hermes_analysis = true
      end

      def hermes_command
        nil
      end

      def configured_jenkins_job_name
        'nn'
      end
    end.new

    report = {
      type: 'App Store Framework 元数据',
      reason: "ERROR ITMS-90060: http://10.1.3.177/job/nn Payload/NNIM.app/Frameworks/libwebp.framework",
      evidence: ["CFBundleShortVersionString '1.5.0.0' in /Users/a1/workspace/nn/libwebp.framework is invalid."],
      suggestions: ['修复 framework Info.plist']
    }

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      helper.run_hermes_publish_evolution(
        event: 'publish_failed',
        report: report,
        target_name: 'TestFlight',
        build_number: 1203,
        result: 'FAILURE',
        failure_lines: ['password=secret token=abcdef /Users/a1/workspace/nn'],
        auto_fix: nil,
        error: nil
      )
    end

    assert_includes output, '【失败案例库】已记录'
    assert File.exist?(db_path)
    record = JSON.parse(File.read(db_path).lines.first)
    assert_equal 'App Store Framework 元数据', record['type']
    assert_equal 'publish_failed', record['event']
    refute_includes record['reason'], '10.1.3.177'
    refute_includes record['failure_lines'].join("\n"), 'secret'
    refute_includes record['failure_lines'].join("\n"), '/Users/a1'
    assert_match(/\A[0-9a-f]{16}\z/, record['fingerprint'])
  ensure
    ENV['COCOAPODS_PODX_FAILURE_CASE_DB'] = original_db
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
    FileUtils.rm_rf(dir) if dir
  end

  def test_hermes_publish_evolution_prompt_includes_failure_case_summaries
    helper = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish
    end.new

    prompt = helper.hermes_publish_evolution_prompt(
      event: 'auto_fix_succeeded',
      report: { type: 'CocoaPods 依赖', reason: 'spec repo stale' },
      target_name: '蒲公英',
      build_number: 1275,
      result: 'FAILURE',
      failure_lines: ['CocoaPods could not find compatible versions'],
      auto_fix: { key: :jenkins_fix_pods, job: 'pod-repo-update' },
      error: nil,
      recent_cases: ['- 2026-05-13 | publish_failed | CocoaPods 依赖 | spec repo stale']
    )

    assert_includes prompt, '历史案例库摘要'
    assert_includes prompt, 'spec repo stale'
    assert_includes prompt, 'auto_fix_succeeded'
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

  def test_publish_only_parses_wechat_notify_options
    publisher = CocoapodsPodx::PublishOnly.new(['publish', '--job', 'nnrtc-ios-build', '--notify-wechat', 'false'])
    assert_equal 'false', publisher.instance_variable_get(:@notify_wechat)

    publisher = CocoapodsPodx::PublishOnly.new(['publish', '--job', 'nnrtc-ios-build', '--notify-wechat=true'])
    assert_equal 'true', publisher.instance_variable_get(:@notify_wechat)

    publisher = CocoapodsPodx::PublishOnly.new(['publish', '--job', 'nnrtc-ios-build', '--no-wechat-notify'])
    assert_equal 'false', publisher.instance_variable_get(:@notify_wechat)
  end

  def test_publish_only_parses_force_private_pod_update_options
    publisher = CocoapodsPodx::PublishOnly.new(['publish', '--job', 'nnrtc-ios-build', '--force-private-pod-update'])
    assert_equal 'true', publisher.instance_variable_get(:@force_private_pod_update)

    publisher = CocoapodsPodx::PublishOnly.new(['publish', '--job', 'nnrtc-ios-build', '--force-private-pod-update', 'false'])
    assert_equal 'false', publisher.instance_variable_get(:@force_private_pod_update)

    publisher = CocoapodsPodx::PublishOnly.new(['publish', '--job', 'nnrtc-ios-build', '--force-private-pod-update=true'])
    assert_equal 'true', publisher.instance_variable_get(:@force_private_pod_update)

    publisher = CocoapodsPodx::PublishOnly.new(['publish', '--job', 'nnrtc-ios-build', '--no-force-private-pod-update'])
    assert_equal 'false', publisher.instance_variable_get(:@force_private_pod_update)
  end

  def test_podx_command_consumes_no_wechat_notify_flag
    command = Pod::Command::Podx.new(FakeArgv.new(flags: { 'wechat-notify' => false }))

    assert_equal 'false', command.instance_variable_get(:@notify_wechat)
  end

  def test_podx_command_consumes_force_private_pod_update_flag
    command = Pod::Command::Podx.new(FakeArgv.new(flags: { 'force-private-pod-update' => true }))
    assert_equal 'true', command.instance_variable_get(:@force_private_pod_update)

    command = Pod::Command::Podx.new(FakeArgv.new(options: { 'force-private-pod-update' => 'false' }))
    assert_equal 'false', command.instance_variable_get(:@force_private_pod_update)
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
      assert_includes output, '【status 汇总】处理 1 个，跳过 1 个'
      Pod::UI.define_singleton_method(:puts, original_puts)
    end
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_mgit_standalone_has_local_repo_sync_for_publish
    assert CocoapodsPodx::MgitStandalone.private_method_defined?(:update_local_repo)
    assert CocoapodsPodx::MgitStandalone.private_method_defined?(:clone_local_repo)
    assert CocoapodsPodx::MgitStandalone.private_method_defined?(:reclone_invalid_local_repo)
    assert CocoapodsPodx::MgitStandalone.private_method_defined?(:git_remote_has_updates?)
  end

  def test_mgit_publish_build_number_uses_release_version_parts
    publisher = Class.new do
      include CocoapodsPodx::Commands::MgitPublish
    end.new

    assert_equal '501402', publisher.mgit_publish_build_number('5.14.2')
    assert_equal '501410', publisher.mgit_publish_build_number('5.14.10')
  end

  def test_mgit_publish_commits_version_to_base_branch_before_release_branch
    project_dir = Dir.mktmpdir('cocoapods-podx-mgit-publish-version-base')
    publisher = Class.new do
      include CocoapodsPodx::Commands::MgitPublish

      attr_reader :commands

      def initialize(project_dir)
        @project_dir = project_dir
        @pod_names = ['release/5.14.8']
        @dry_run = false
        @git_publish_base_branch = nil
        @git_publish_push_mode = nil
        @git_publish_work_dir = nil
        @commands = []
      end

      def project_directory
        @project_dir
      end

      def mgit_publish_config
        {
          work_dir: '.mgit-publish',
          base_branch: 'develop',
          repos: nil,
          main_repo: 'nnios',
          update_podfile_branch: true,
        }
      end

      def mgit_publish_repos
        [{ name: 'nnios', url: 'http://git.example.com/nn_ios/nnios.git' }]
      end

      def mgit_publish_version_config
        {
          type: 'ios_xcodeproj',
          branch_pattern: '^release/(\\d+\\.\\d+\\.\\d+)$',
          project_file: 'NNIM.xcodeproj/project.pbxproj',
          build_number_strategy: 'ios_semver',
        }
      end

      def run_git!(path, *args)
        @commands << [path, args]
        if args.first == 'clone'
          repo_dir = args.last
          FileUtils.mkdir_p(File.join(repo_dir, 'NNIM.xcodeproj'))
          File.write(File.join(repo_dir, 'Podfile'), "pod 'NNLibrary', :branch => 'develop'\n")
          File.write(File.join(repo_dir, 'NNIM.xcodeproj', 'project.pbxproj'), <<~PROJECT)
            MARKETING_VERSION = 5.14.7;
            CURRENT_PROJECT_VERSION = 501407;
          PROJECT
        end
        ''
      end

      def checkout_branch!(repo_dir, branch)
        @commands << [repo_dir, ['checkout_branch!', branch]]
      end

      def git_dirty?(_repo_dir)
        true
      end

      def git_work_tree?(_repo_dir)
        false
      end
    end.new(project_dir)

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |_message = ''| }
    publisher.publish_git_branches

    command_args = publisher.commands.map(&:last)
    base_push_index = command_args.index(['push', 'origin', 'develop'])
    release_checkout_index = command_args.index(['checkout', '-B', 'release/5.14.8', 'develop'])
    release_push_index = command_args.index(['push', 'origin', 'release/5.14.8'])

    refute_nil base_push_index
    refute_nil release_checkout_index
    refute_nil release_push_index
    assert_operator base_push_index, :<, release_checkout_index
    assert_operator release_checkout_index, :<, release_push_index
    assert_includes command_args, ['commit', '-m', 'chore: update version to 5.14.8(501408) for develop']
    assert_includes command_args, ['commit', '-m', 'chore: update publish config to release/5.14.8']
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_mgit_publish_rejects_placeholder_release_branch
    publisher = Class.new do
      include CocoapodsPodx::Commands::MgitPublish
    end.new

    error = assert_raises(Pod::Informative) do
      publisher.validate_mgit_publish_target_branch!('release/x.x.x')
    end

    assert_includes error.message, '发布分支不能使用示例占位符'
    assert_includes error.message, 'mgit publish release/5.14.2'

    error = assert_raises(Pod::Informative) do
      publisher.validate_mgit_publish_target_branch!('BRANCH')
    end

    assert_includes error.message, '发布分支不能使用示例占位符'
  end

  def test_mgit_publish_allows_feature_and_release_branches
    publisher = Class.new do
      include CocoapodsPodx::Commands::MgitPublish
    end.new

    publisher.validate_mgit_publish_target_branch!('release/5.14.2')
    publisher.validate_mgit_publish_target_branch!('feature/5.14.5_felix_test')

    error = assert_raises(Pod::Informative) { publisher.validate_mgit_publish_target_branch!('--branch') }
    assert_includes error.message, '发布分支格式不正确'
  end

  def test_mgit_publish_cleanup_work_dir_keeps_empty_work_dir
    publisher = Class.new do
      include CocoapodsPodx::Commands::MgitPublish
    end.new

    work_dir = Dir.mktmpdir('cocoapods-podx-mgit-publish-work')
    FileUtils.mkdir_p(File.join(work_dir, 'nnios', '.git'))
    FileUtils.mkdir_p(File.join(work_dir, 'nnbusscom'))
    File.write(File.join(work_dir, 'log.txt'), 'debug')

    publisher.mgit_publish_cleanup_work_dir(work_dir)

    assert File.directory?(work_dir)
    assert_empty Dir.children(work_dir)
  ensure
    FileUtils.rm_rf(work_dir) if work_dir
  end

  def test_mgit_publish_creates_component_branch_by_api_without_git_fetch
    publisher = Class.new do
      include CocoapodsPodx::Commands::MgitPublish

      attr_reader :api_args, :commands

      def initialize
        @api_args = []
        @commands = []
      end

      def mgit_publish_create_remote_branch_via_api(url, base_branch, target_branch)
        @api_args << [url, base_branch, target_branch]
        true
      end

      def run_git!(path, *args)
        @commands << [path, args]
      end
    end.new

    publisher.mgit_publish_push_remote_repo_branch(
      'http://git.example.com/nn_ios/nnbusscom.git',
      'develop',
      'release/5.14.2',
      'normal'
    )

    assert_equal [['http://git.example.com/nn_ios/nnbusscom.git', 'develop', 'release/5.14.2']], publisher.api_args
    assert_empty publisher.commands
  end

  def test_mgit_publish_falls_back_to_shallow_fetch_without_clone
    publisher = Class.new do
      include CocoapodsPodx::Commands::MgitPublish

      attr_reader :commands

      def initialize
        @commands = []
      end

      def project_directory
        '/tmp/app'
      end

      def mgit_publish_create_remote_branch_via_api(_url, _base_branch, _target_branch)
        false
      end

      def run_git!(path, *args)
        @commands << [path, args]
        return "abcdef1234567890\trefs/heads/develop\n" if args.first == 'ls-remote'

        ''
      end
    end.new

    publisher.mgit_publish_push_remote_repo_branch(
      'http://git.example.com/nn_ios/nnbusscom.git',
      'develop',
      'release/5.14.2',
      'normal'
    )

    command_args = publisher.commands.map(&:last)
    assert_equal ['ls-remote', 'http://git.example.com/nn_ios/nnbusscom.git', 'refs/heads/develop'], command_args[0]
    assert_includes command_args, ['init', '-q']
    assert_includes command_args, ['fetch', '--depth', '1', 'http://git.example.com/nn_ios/nnbusscom.git', 'refs/heads/develop']
    assert_includes command_args, ['push', 'http://git.example.com/nn_ios/nnbusscom.git', 'FETCH_HEAD:refs/heads/release/5.14.2']
    refute publisher.commands.any? { |_path, args| args.include?('clone') }
  end

  def test_mgit_publish_api_auth_failure_falls_back_to_git
    publisher = Class.new do
      include CocoapodsPodx::Commands::MgitPublish
    end.new

    original_start = Net::HTTP.method(:start)
    original_token = ENV['COCOAPODS_PODX_GIT_TOKEN']
    ENV['COCOAPODS_PODX_GIT_TOKEN'] = 'invalid-token'

    [401, 403].each do |status_code|
      Net::HTTP.define_singleton_method(:start) do |*_args, &_block|
        Struct.new(:code, :body).new(status_code.to_s, '')
      end

      refute publisher.mgit_publish_create_remote_branch_via_api(
        'http://git.example.com/nn_ios/nnbusscom.git',
        'develop',
        'release/5.14.2'
      )
    end
  ensure
    Net::HTTP.define_singleton_method(:start, original_start) if original_start
    if original_token
      ENV['COCOAPODS_PODX_GIT_TOKEN'] = original_token
    else
      ENV.delete('COCOAPODS_PODX_GIT_TOKEN')
    end
  end

  def test_mgit_publish_component_skip_mode_only_checks_remote_base_branch
    publisher = Class.new do
      include CocoapodsPodx::Commands::MgitPublish

      attr_reader :commands

      def initialize
        @commands = []
      end

      def project_directory
        '/tmp/app'
      end

      def run_git!(path, *args)
        @commands << [path, args]
        "abcdef1234567890\trefs/heads/develop\n"
      end
    end.new

    publisher.mgit_publish_push_remote_repo_branch(
      'http://git.example.com/nn_ios/nnbusscom.git',
      'develop',
      'release/5.14.2',
      'skip'
    )

    assert_equal 1, publisher.commands.length
    assert_equal ['ls-remote', 'http://git.example.com/nn_ios/nnbusscom.git', 'refs/heads/develop'], publisher.commands.first[1]
  end

  def test_mgit_publish_output_hides_config_and_local_checkout_tables
    publisher = Class.new do
      include CocoapodsPodx::Commands::MgitPublish

      def initialize(project_dir)
        @project_dir = project_dir
        @pod_names = ['feature/5.14.9_newimprove']
        @dry_run = true
        @git_publish_base_branch = nil
        @git_publish_push_mode = nil
        @git_publish_work_dir = nil
      end

      def project_directory
        @project_dir
      end
    end.new(@project_dir)

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      publisher.publish_git_branches
    end

    assert_includes output, 'mgit publish feature/5.14.9_newimprove 预览中...'
    assert_includes output, '【mgit publish 预览】'
    assert_includes output, 'mgit publish feature/5.14.9_newimprove 预览完成'
    assert_match(/【publish 耗时】\d+(?:m\d{2})?s/, output)
    refute_includes output, '【mgit publish 配置】'
    refute_includes output, '【本地仓库切换'
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_mgit_publish_builds_gitlab_create_branch_uri
    publisher = Class.new do
      include CocoapodsPodx::Commands::MgitPublish
    end.new

    uri = publisher.mgit_publish_gitlab_create_branch_uri('http://git.leigod.top/nn_ios/nnbusscom.git')

    assert_equal 'http://git.leigod.top/api/v4/projects/nn_ios%2Fnnbusscom/repository/branches', uri.to_s
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

  def test_podx_init_creates_missing_overlay_file
    overlay_path = File.join(@project_dir, 'Podfile.overlay')
    FileUtils.rm_f(overlay_path)

    command = Pod::Command::Podx.allocate
    command.instance_variable_set(:@project_directory, @project_dir)
    command.send(:init_project_overlay_file)

    assert File.exist?(overlay_path)
    content = File.read(overlay_path)
    assert_includes content, '# 本地源码覆盖配置'
    assert_includes content, "# pod 'NNBussCom'"
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
        %w[仓库 来源 分支 更新 Commit],
        [
          ['main', '本地', 'feature/5.14.2_broadcast', '有更新', 'bd5ad0 update: 发布cocoapods-podx 0.0.35'],
          ['NNLibrary', '远端', 'feature/5.14.2_broadcast', '-', '258c70']
        ]
      )
    end

    assert_includes output, '【pull 结果】'
    assert_includes output, '| 仓库'
    assert_includes output, '| 来源'
    assert_includes output, '本地'
    assert_includes output, '远端'
    refute_includes output, '路径'
    assert_includes output, '有更新'
    assert_includes output, 'bd5ad0 update'
    assert_includes output, '258c70'

    table_lines = output.lines.map(&:chomp).select { |line| line.start_with?('|', '+') }
    widths = table_lines.map { |line| helper.git_action_display_width(line) }
    assert_equal 1, widths.uniq.length
    assert_equal 4, helper.git_action_display_width("\e[31m失败\e[0m")
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_git_actions_colors_update_and_skip_like_local_source
    helper = Class.new do
      include CocoapodsPodx::Commands::GitActions

      def git_action_color_enabled?
        true
      end
    end.new

    assert_includes helper.git_action_color_cell('本地', '本地'), "\e[36m"
    assert_includes helper.git_action_color_cell('有更新', '有更新'), "\e[36m"
    assert_includes helper.git_action_color_cell('跳过', '跳过'), "\e[36m"
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
        @heads[path] = 'bbbbbb' if args == ['pull', '--rebase', '--autostash', 'origin', @branches[path]]
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

    assert_match(/\| NNApperance\s+\| 本地\s+\| feature\/5\.14\.2_broadcast \| 有更新/, output)
    assert_includes output, 'bbbbbb update'
    assert_includes helper.commands, [component_path, ['fetch', 'origin']]
    assert_includes helper.commands, [component_path, ['checkout_branch!', 'feature/5.14.2_broadcast']]
    assert_includes helper.commands, [component_path, ['pull', '--rebase', '--autostash', 'origin', 'feature/5.14.2_broadcast']]
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_git_actions_pull_shows_commit_hash_when_no_update
    project_dir = Dir.mktmpdir('cocoapods-podx-git-actions')
    FileUtils.mkdir_p(project_dir)

    helper = Class.new do
      include CocoapodsPodx::Commands::GitActions

      attr_reader :commands

      def initialize(project_directory)
        @project_directory = project_directory
        @pull_mode = true
        @pod_names = []
        @dry_run = false
        @commands = []
      end

      def project_directory
        @project_directory
      end

      def commit_targets(_entries)
        [{ name: 'main', path: @project_directory }]
      end

      def git_work_tree?(_path)
        true
      end

      def git_branch_for(_path)
        'develop'
      end

      def git_status_lines(_path)
        []
      end

      def git_dirty?(_path)
        false
      end

      def run_git!(path, *args)
        @commands << [path, args]
        ''
      end

      def git_short_head(_path)
        'c4e14d'
      end
    end.new(project_dir)

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      helper.git_action_repos([])
    end

    assert_includes output, '| main | 本地 | develop | -'
    assert_includes output, '| c4e14d |'
    assert_includes helper.commands, [project_dir, ['pull', '--rebase', '--autostash', 'origin', 'develop']]
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_git_actions_pull_uses_autostash_when_current_branch_is_dirty
    project_dir = Dir.mktmpdir('cocoapods-podx-git-actions')
    FileUtils.mkdir_p(project_dir)

    helper = Class.new do
      include CocoapodsPodx::Commands::GitActions

      attr_reader :commands

      def initialize(project_directory)
        @project_directory = project_directory
        @pull_mode = true
        @pod_names = []
        @dry_run = false
        @commands = []
      end

      def project_directory
        @project_directory
      end

      def commit_targets(_entries)
        [{ name: 'main', path: @project_directory }]
      end

      def git_work_tree?(_path)
        true
      end

      def git_branch_for(_path)
        'develop'
      end

      def git_status_lines(_path)
        [' M Podfile']
      end

      def git_dirty?(_path)
        true
      end

      def run_git!(path, *args)
        @commands << [path, args]
        ''
      end
    end.new(project_dir)

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    capture_io do
      helper.git_action_repos([])
    end

    assert_includes helper.commands, [project_dir, ['pull', '--rebase', '--autostash', 'origin', 'develop']]
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_git_actions_pull_skips_dirty_repo_when_branch_needs_checkout
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
        path == @project_directory ? 'develop' : 'release/5.14.3'
      end

      def git_status_lines(path)
        path == @component_path ? [' M Podfile'] : []
      end

      def git_dirty?(path)
        path == @component_path
      end

      def run_git!(path, *args)
        @commands << [path, args]
        ''
      end
    end.new(main_path, component_path)

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      helper.git_action_repos([])
    end

    assert_includes output, '分支不一致且有本地变更'
    refute helper.commands.any? { |path, args| path == component_path && args.first == 'pull' }
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_git_actions_pull_ff_only_uses_git_pull_ff_only
    project_dir = Dir.mktmpdir('cocoapods-podx-git-actions')
    FileUtils.mkdir_p(project_dir)

    helper = Class.new do
      include CocoapodsPodx::Commands::GitActions

      attr_reader :commands

      def initialize(project_directory)
        @project_directory = project_directory
        @pull_mode = true
        @pull_ff_only = true
        @pod_names = []
        @dry_run = false
        @commands = []
      end

      def project_directory
        @project_directory
      end

      def commit_targets(_entries)
        [{ name: 'main', path: @project_directory }]
      end

      def git_work_tree?(_path)
        true
      end

      def git_branch_for(_path)
        'develop'
      end

      def git_status_lines(_path)
        []
      end

      def git_dirty?(_path)
        false
      end

      def run_git!(path, *args)
        @commands << [path, args]
        ''
      end

      def git_short_head(_path)
        'c4e14d'
      end
    end.new(project_dir)

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    capture_io do
      helper.git_action_repos([])
    end

    assert_includes helper.commands, [project_dir, ['pull', '--ff-only', 'origin', 'develop']]
    refute_includes helper.commands, [project_dir, ['pull', '--rebase', 'origin', 'develop']]
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_git_actions_rebase_continue_only_runs_for_rebasing_repos
    project_dir = Dir.mktmpdir('cocoapods-podx-git-actions')
    component_path = File.join(project_dir, 'Development Pods', 'NNLibrary')
    FileUtils.mkdir_p(project_dir)
    FileUtils.mkdir_p(component_path)

    helper = Class.new do
      include CocoapodsPodx::Commands::GitActions

      attr_reader :commands

      def initialize(project_directory, component_path)
        @project_directory = project_directory
        @component_path = component_path
        @rebase_mode = true
        @rebase_continue_mode = true
        @pod_names = []
        @dry_run = false
        @commands = []
      end

      def project_directory
        @project_directory
      end

      def commit_targets(_entries)
        [
          { name: 'main', path: @project_directory },
          { name: 'NNLibrary', path: @component_path }
        ]
      end

      def git_work_tree?(_path)
        true
      end

      def git_branch_for(_path)
        'develop'
      end

      def git_status_lines(_path)
        []
      end

      def git_rebase_in_progress?(path)
        path == @component_path
      end

      def run_git!(path, *args)
        @commands << [path, args]
        ''
      end
    end.new(project_dir, component_path)

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      helper.git_action_repos([])
    end

    assert_includes helper.commands, [component_path, ['rebase', '--continue']]
    refute_includes helper.commands, [project_dir, ['rebase', '--continue']]
    assert_match(/\| main\s+\| develop \| 跳过\s+\|/, output)
    assert_match(/\| NNLibrary \| develop \| 已继续 \|/, output)
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_git_actions_rebase_abort_runs_git_rebase_abort
    project_dir = Dir.mktmpdir('cocoapods-podx-git-actions')
    FileUtils.mkdir_p(project_dir)

    helper = Class.new do
      include CocoapodsPodx::Commands::GitActions

      attr_reader :commands

      def initialize(project_directory)
        @project_directory = project_directory
        @rebase_mode = true
        @rebase_abort_mode = true
        @pod_names = []
        @dry_run = false
        @commands = []
      end

      def project_directory
        @project_directory
      end

      def commit_targets(_entries)
        [{ name: 'main', path: @project_directory }]
      end

      def git_work_tree?(_path)
        true
      end

      def git_branch_for(_path)
        'develop'
      end

      def git_status_lines(_path)
        []
      end

      def git_rebase_in_progress?(_path)
        true
      end

      def run_git!(path, *args)
        @commands << [path, args]
        ''
      end
    end.new(project_dir)

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      helper.git_action_repos([])
    end

    assert_includes helper.commands, [project_dir, ['rebase', '--abort']]
    assert_match(/\| main \| develop \| 已放弃 \|/, output)
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_git_actions_pull_lists_remote_components_not_in_overlay
    project_dir = Dir.mktmpdir('cocoapods-podx-git-actions')
    main_path = File.join(project_dir, 'main')
    buss_path = File.join(project_dir, 'Development Pods', 'nnbusscom')
    FileUtils.mkdir_p(main_path)
    FileUtils.mkdir_p(buss_path)

    helper = Class.new do
      include CocoapodsPodx::Commands::GitActions

      attr_reader :commands

      def initialize(project_directory, buss_path)
        @project_directory = project_directory
        @buss_path = buss_path
        @pull_mode = true
        @pod_names = []
        @dry_run = false
        @commands = []
        @branches = {
          project_directory => 'develop',
          buss_path => 'develop'
        }
      end

      def project_directory
        @project_directory
      end

      def supported_overlay_names
        %w[NNBussCom NNLibrary]
      end

      def local_repo_path_for(name)
        name == 'NNBussCom' ? @buss_path : File.join(@project_directory, 'Development Pods', name)
      end

      def declared_branch_for(_name)
        'develop'
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
        ''
      end

      def git_short_head(path)
        path == @project_directory ? '89b272' : 'f0fdc2'
      end
    end.new(main_path, buss_path)

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      helper.git_action_repos([{ name: 'NNBussCom' }])
    end

    assert_match(/\| NNBussCom\s+\| 本地 \| develop \| -\s+\| f0fdc2 \|/, output)
    assert_match(/\| NNLibrary\s+\| 远端 \| develop \| -\s+\|\s+\|/, output)
    assert_includes helper.commands, [buss_path, ['pull', '--rebase', '--autostash', 'origin', 'develop']]
    refute helper.commands.any? { |path, _args| path.to_s.include?('NNLibrary') }
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

  def test_git_actions_merge_restores_main_protected_files
    project_dir = Dir.mktmpdir('cocoapods-podx-git-merge-protected')
    main_path = File.join(project_dir, 'main')
    FileUtils.mkdir_p(main_path)

    helper = Class.new do
      include CocoapodsPodx::Commands::GitActions

      attr_reader :commands

      def initialize(main_path)
        @project_directory = main_path
        @merge_mode = true
        @merge_branch = 'develop'
        @pod_names = ['main']
        @dry_run = false
        @commands = []
        @branch = 'feature/5.14.2_broadcast'
        @head = '1111111111111111111111111111111111111111'
      end

      def project_directory
        @project_directory
      end

      def commit_targets(_entries)
        [{ name: 'main', path: @project_directory }]
      end

      def git_work_tree?(_path)
        true
      end

      def git_branch_for(_path)
        @branch
      end

      def git_status_lines(_path)
        []
      end

      def git_dirty?(_path)
        false
      end

      def git_full_head(_path)
        @head
      end

      def git_action_protected_files_for_merge(_name)
        %w[Podfile]
      end

      def git_path_changed_between?(_path, _before_commit, _after_commit, file)
        file == 'Podfile'
      end

      def git_path_exists_at?(_path, _commit, file)
        file == 'Podfile'
      end

      def run_git!(path, *args)
        @commands << [path, args]
        @head = '2222222222222222222222222222222222222222' if args == ['merge', '--no-edit', '--no-stat', '--no-ff', 'origin/develop']
        @head = '3333333333333333333333333333333333333333' if args == ['commit', '--amend', '--no-edit']
        ''
      end

      def git_commit_summary(_path, commit)
        "#{commit[0, 6]} merge"
      end
    end.new(main_path)

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      helper.git_action_repos([])
    end

    assert_includes output, '【merge 结果】'
    assert_includes output, '| main | feature/5.14.2_broadcast | 已合并 |'
    assert_includes helper.commands, [main_path, ['merge', '--no-edit', '--no-stat', '--no-ff', 'origin/develop']]
    assert_includes helper.commands, [main_path, ['checkout', '1111111111111111111111111111111111111111', '--', 'Podfile']]
    assert_includes helper.commands, [main_path, ['commit', '--amend', '--no-edit']]
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_git_actions_merge_includes_components_changed_on_source_branch
    project_dir = Dir.mktmpdir('cocoapods-podx-git-merge-extra')
    paths = {
      'main' => File.join(project_dir, 'main'),
      'NNBussCom' => File.join(project_dir, 'Development Pods', 'NNBussCom'),
      'NNIMManager' => File.join(project_dir, 'Development Pods', 'NNIMManager'),
      'NNBasciCommon' => File.join(project_dir, 'Development Pods', 'NNBasciCommon'),
      'NNRealReachability' => File.join(project_dir, 'Development Pods', 'NNRealReachability')
    }
    paths.values.each { |path| FileUtils.mkdir_p(path) }

    helper = Class.new do
      include CocoapodsPodx::Commands::GitActions

      attr_reader :commands

      def initialize(paths)
        @paths = paths
        @project_directory = paths.fetch('main')
        @merge_mode = true
        @merge_branch = 'develop'
        @pod_names = []
        @dry_run = false
        @commands = []
        @branches = paths.values.each_with_object({}) { |path, memo| memo[path] = 'feature/5.14.2_websocket' }
        @heads = Hash.new('1111111111111111111111111111111111111111')
      end

      def project_directory
        @project_directory
      end

      def local_repo_path_for(name)
        @paths.fetch(name)
      end

      def supported_overlay_names
        %w[NNBussCom NNBasciCommon NNRealReachability NNIMManager]
      end

      def merge_branch_component_changed?(name)
        %w[NNBasciCommon NNRealReachability].include?(name)
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

      def checkout_branch!(path, branch)
        @commands << [path, ['checkout_branch!', branch]]
        @branches[path] = branch
      end

      def git_commit_summary(_path, commit)
        "#{commit[0, 6]} merge"
      end
    end.new(paths)

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      helper.git_action_repos([{ name: 'NNBussCom' }, { name: 'NNIMManager' }])
    end

    assert_includes output, '| NNBussCom          | feature/5.14.2_websocket | 已合并 |'
    assert_includes output, '| NNIMManager        | feature/5.14.2_websocket | 已合并 |'
    assert_includes output, '| NNBasciCommon      | feature/5.14.2_websocket | 已合并 |'
    assert_includes output, '| NNRealReachability | feature/5.14.2_websocket | 已合并 |'
    assert_includes helper.commands, [paths.fetch('NNBasciCommon'), ['checkout_branch!', 'develop']]
    assert_includes helper.commands, [paths.fetch('NNBasciCommon'), ['pull', '--ff-only', 'origin', 'develop']]
    assert_includes helper.commands, [paths.fetch('NNBasciCommon'), ['checkout_branch!', 'feature/5.14.2_websocket']]
    assert_includes helper.commands, [paths.fetch('NNBasciCommon'), ['merge', '--no-edit', '--no-stat', 'origin/develop']]
    assert_includes helper.commands, [paths.fetch('NNRealReachability'), ['merge', '--no-edit', '--no-stat', 'origin/develop']]
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_git_actions_merge_writes_all_supported_components_to_overlay
    project_dir = Dir.mktmpdir('cocoapods-podx-git-merge-overlay')
    overlay_path = File.join(project_dir, 'Podfile.overlay')
    File.write(overlay_path, <<~RUBY)
      # 本地源码覆盖配置
      # 示例：

      pod 'NNBussCom'
    RUBY

    paths = {
      'main' => project_dir,
      'NNBussCom' => File.join(project_dir, 'Development Pods', 'NNBussCom'),
      'NNBasciCommon' => File.join(project_dir, 'Development Pods', 'NNBasciCommon'),
      'NNRealReachability' => File.join(project_dir, 'Development Pods', 'NNRealReachability')
    }
    paths.values.each { |path| FileUtils.mkdir_p(path) }

    helper = Class.new do
      include CocoapodsPodx::Commands::GitActions

      def initialize(paths, overlay_path)
        @paths = paths
        @overlay_path = overlay_path
        @project_directory = paths.fetch('main')
        @merge_mode = true
        @merge_branch = 'develop'
        @pod_names = []
        @dry_run = false
      end

      def project_directory
        @project_directory
      end

      def overlay_path
        @overlay_path
      end

      def local_repo_path_for(name)
        @paths.fetch(name)
      end

      def supported_overlay_names
        %w[NNBussCom NNBasciCommon NNRealReachability]
      end

      def git_work_tree?(_path)
        true
      end

      def git_branch_for(_path)
        'feature/5.14.2_websocket'
      end

      def git_status_lines(_path)
        []
      end
    end.new(paths, overlay_path)

    helper.send(:sync_overlay_to_all_merge_components, [{ name: 'NNBussCom' }])

    content = File.read(overlay_path)
    assert_includes content, "pod 'NNBussCom'"
    assert_includes content, "pod 'NNBasciCommon'"
    assert_includes content, "pod 'NNRealReachability'"
  ensure
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_git_hooks_install_pre_commit_protects_configured_files
    project_dir = Dir.mktmpdir('cocoapods-podx-hooks')
    main_path = File.join(project_dir, 'main')
    component_path = File.join(project_dir, 'Development Pods', 'NNBussCom')
    FileUtils.mkdir_p(File.join(main_path, '.git', 'hooks'))
    FileUtils.mkdir_p(File.join(component_path, '.git', 'hooks'))
    File.write(File.join(project_dir, 'podx.config.yml'), <<~YAML)
      protected_commit_files:
        - Podfile
    YAML

    helper = Class.new do
      include CocoapodsPodx::Commands::GitActions
      include CocoapodsPodx::Commands::GitHooks

      def initialize(project_dir, main_path, component_path)
        @project_directory = main_path
        @config_path = File.join(project_dir, 'podx.config.yml')
        @component_path = component_path
        @dry_run = false
      end

      def project_directory
        @project_directory
      end

      def config_path
        @config_path
      end

      def local_repo_path_for(_name)
        @component_path
      end

      def git_work_tree?(_path)
        true
      end

      def run_git!(path, *args)
        (@commands ||= []) << [path, args]
        ''
      end

      attr_reader :commands
    end.new(project_dir, main_path, component_path)

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      helper.install_git_hooks([{ name: 'NNBussCom' }])
    end

    main_hook = File.read(File.join(main_path, '.githooks', 'pre-commit'))
    main_post_merge_hook = File.read(File.join(main_path, '.githooks', 'post-merge'))
    assert_includes main_hook, 'cocoapods-podx protected files hook'
    assert_includes main_hook, "'Podfile'"
    assert_includes main_hook, 'COCOAPODS_PODX_ALLOW_PROTECTED_COMMIT'
    assert_includes main_hook, 'mgit_publish'
    assert_includes main_post_merge_hook, 'cocoapods-podx protected files post-merge hook'
    assert_includes main_post_merge_hook, 'git checkout ORIG_HEAD -- "$protected_file"'
    assert_includes main_post_merge_hook, 'pull/merge 后已还原'
    refute_includes main_hook, "'Podflie.rb'"
    assert_includes output, '【hooks 结果】'
    assert_includes output, '【hooks 规则】'
    assert_includes output, '| 提交保护 | 配置'
    assert_includes output, '| 合并保护 | 配置'
    assert_includes output, 'publish/commit-edit'
    assert_includes output, '| main'
    refute_includes output, 'NNBussCom'
    assert_includes helper.commands, [main_path, ['config', 'core.hooksPath', '.githooks']]
    refute File.exist?(File.join(component_path, '.githooks', 'pre-commit'))
    refute File.exist?(File.join(component_path, '.githooks', 'post-merge'))
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_git_hooks_upsert_replaces_existing_podx_block
    helper = Class.new do
      include CocoapodsPodx::Commands::GitHooks
    end.new

    original = <<~SH
      #!/bin/sh
      echo before

      # >>> cocoapods-podx protected files hook
      old
      # <<< cocoapods-podx protected files hook
    SH
    updated = helper.upsert_podx_hook(original, %w[Podfile])

    assert_includes updated, 'echo before'
    assert_includes updated, "'Podfile'"
    refute_includes updated, "\nold\n"
    assert_equal 1, updated.scan('cocoapods-podx protected files hook').length / 2
  end

  def test_git_hooks_upsert_replaces_existing_post_merge_block
    helper = Class.new do
      include CocoapodsPodx::Commands::GitHooks
    end.new

    original = <<~SH
      #!/bin/sh
      echo before

      # >>> cocoapods-podx protected files post-merge hook
      old
      # <<< cocoapods-podx protected files post-merge hook
    SH
    updated = helper.upsert_podx_post_merge_hook(original, %w[Podfile])

    assert_includes updated, 'echo before'
    assert_includes updated, "'Podfile'"
    assert_includes updated, 'git checkout ORIG_HEAD -- "$protected_file"'
    refute_includes updated, "\nold\n"
    assert_equal 1, updated.scan('cocoapods-podx protected files post-merge hook').length / 2
  end

  def test_git_hooks_default_protected_files_are_used_without_config
    helper = Class.new do
      include CocoapodsPodx::Commands::GitHooks

      def config_path
        '/tmp/missing-podx-config.yml'
      end
    end.new

    assert_equal %w[Podfile], helper.protected_commit_files
  end

  def test_rules_commit_protection_uses_configured_files_instead_of_defaults
    config_dir = Dir.mktmpdir('cocoapods-podx-rules')
    config_path = File.join(config_dir, 'podx.config.yml')
    File.write(config_path, <<~YAML)
      protected_commit_files:
        - Podfile
    YAML

    rule = CocoapodsPodx::Rules.engine(config_path: config_path).commit_protection

    assert_equal %w[Podfile], rule.protected_files
    assert_equal [], rule.protected_files_for(scope: :component)
    assert_equal '配置', rule.protected_files_source
    assert_equal 'COCOAPODS_PODX_ALLOW_PROTECTED_COMMIT', rule.allow_env
    assert_equal 'mgit_publish', rule.allow_context
  ensure
    FileUtils.rm_rf(config_dir) if config_dir
  end

  def test_rules_commit_protection_reports_default_source
    rule = CocoapodsPodx::Rules.engine(config_path: '/tmp/missing-podx-config.yml').commit_protection

    assert_equal %w[Podfile], rule.protected_files
    assert_equal [], rule.protected_files_for(scope: :component)
    assert_equal '默认', rule.protected_files_source
  end

  def test_rules_summaries_include_publish_version_and_branch_rules
    config_dir = Dir.mktmpdir('cocoapods-podx-rule-summaries')
    config_path = File.join(config_dir, 'podx.config.yml')
    File.write(config_path, <<~YAML)
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

    rows = CocoapodsPodx::Rules.engine(config_path: config_path).summaries

    assert_includes rows, ['发布分支', '配置', 'develop->release/x.x.x', 'mgit publish']
    assert_includes rows, ['合并保护', '默认', '还原Podfile', 'pull/merge']
    assert_includes rows, ['本地产物', '默认', '.mgit-publish/, Development Pods/, .codegraphignore, .code-review-graphignore, .podx/skills.yml, .podx/codegraph_ignore, .podx/skill_runs.yml, .podx/skill_snapshot.md, .podx/skill_ci.json, .podx/rules_snapshot.json, .podx/pipeline_ci.sh, .podx/pipeline_snapshot.json, .podx/pipeline_report.md', '.gitignore']
    assert_includes rows, ['Podfile分支', '配置', '组件branch->发布分支', 'mgit publish']
    assert_includes rows, ['iOS版本', '配置', '改Version/Build', 'mgit publish']
    refute rows.any? { |row| row.first == 'iOS Build' }
    assert_includes rows, ['发布渠道', '内置', 'tf/app仅release', 'podx publish']
  ensure
    FileUtils.rm_rf(config_dir) if config_dir
  end

  def test_rules_local_artifacts_use_configured_publish_work_dir
    config_dir = Dir.mktmpdir('cocoapods-podx-local-artifacts')
    config_path = File.join(config_dir, 'podx.config.yml')
    File.write(config_path, <<~YAML)
      publish_work_dir: .release-work
    YAML

    rules = CocoapodsPodx::Rules.local_artifact_gitignore_rules(config_path: config_path)

    assert_equal ['.release-work/', 'Development Pods/', '.codegraphignore', '.code-review-graphignore', '.podx/skills.yml', '.podx/codegraph_ignore', '.podx/skill_runs.yml', '.podx/skill_snapshot.md', '.podx/skill_ci.json', '.podx/rules_snapshot.json', '.podx/pipeline_ci.sh', '.podx/pipeline_snapshot.json', '.podx/pipeline_report.md'], rules
  ensure
    FileUtils.rm_rf(config_dir) if config_dir
  end

  def test_rules_local_artifacts_detect_missing_gitignore_rules
    rule = CocoapodsPodx::Rules.engine(config_path: '/tmp/missing-podx-config.yml').local_artifacts

    missing = rule.missing_gitignore_rules(".mgit-publish/\nDevelopment Pods/\n")

    assert_equal ['.codegraphignore', '.code-review-graphignore', '.podx/skills.yml', '.podx/codegraph_ignore', '.podx/skill_runs.yml', '.podx/skill_snapshot.md', '.podx/skill_ci.json', '.podx/rules_snapshot.json', '.podx/pipeline_ci.sh', '.podx/pipeline_snapshot.json', '.podx/pipeline_report.md'], missing
  end

  def test_podx_rules_check_fails_when_gitignore_is_missing_rules
    project_dir = Dir.mktmpdir('cocoapods-podx-rules-check')
    File.write(File.join(project_dir, '.gitignore'), ".mgit-publish/\n")
    helper = rules_command_helper(project_dir)

    error = assert_raises(Pod::Informative) { helper.check_podx_rules }

    assert_includes error.message, 'rules check 失败'
  ensure
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_podx_rules_sync_writes_missing_gitignore_rules
    project_dir = Dir.mktmpdir('cocoapods-podx-rules-sync')
    File.write(File.join(project_dir, '.gitignore'), ".mgit-publish/\n")
    helper = rules_command_helper(project_dir)

    helper.sync_podx_rules
    content = File.read(File.join(project_dir, '.gitignore'))

    assert_includes content, '.mgit-publish/'
    assert_includes content, 'Development Pods/'
    assert_includes content, '.podx/skills.yml'
    assert_includes content, '.podx/skill_runs.yml'
    assert_includes content, '.podx/skill_snapshot.md'
    assert_includes content, '.podx/skill_ci.json'
    assert_includes content, '.podx/rules_snapshot.json'
    assert_includes content, '.podx/pipeline_ci.sh'
    assert_includes content, '.podx/pipeline_snapshot.json'
    assert_includes content, '.podx/pipeline_report.md'
  ensure
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_podx_rules_snapshot_writes_json_payload
    project_dir = Dir.mktmpdir('cocoapods-podx-rules-snapshot')
    File.write(File.join(project_dir, '.gitignore'), ".mgit-publish/\n")
    helper = rules_command_helper(project_dir)

    helper.snapshot_podx_rules
    payload = JSON.parse(File.read(File.join(project_dir, '.podx', 'rules_snapshot.json')))

    assert_equal 'fail', payload['status']
    assert_includes payload['missing_gitignore_rules'], 'Development Pods/'
    assert payload['summaries'].any? { |row| row['rule'] == '本地产物' }
    assert payload['local_artifacts'].any? { |row| row['rule'] == '.podx/skills.yml' }
    assert payload['local_artifacts'].any? { |row| row['rule'] == '.podx/codegraph_ignore' }
    assert payload['local_artifacts'].any? { |row| row['rule'] == '.code-review-graphignore' }
    assert payload['local_artifacts'].any? { |row| row['rule'] == '.podx/rules_snapshot.json' }
    assert payload['local_artifacts'].any? { |row| row['rule'] == '.podx/pipeline_ci.sh' }
    assert payload['local_artifacts'].any? { |row| row['rule'] == '.podx/pipeline_snapshot.json' }
    assert payload['local_artifacts'].any? { |row| row['rule'] == '.podx/pipeline_report.md' }
  ensure
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_podx_rules_ci_fails_and_writes_snapshot_when_rules_missing
    project_dir = Dir.mktmpdir('cocoapods-podx-rules-ci')
    File.write(File.join(project_dir, '.gitignore'), ".mgit-publish/\n")
    helper = rules_command_helper(project_dir)

    error = assert_raises(Pod::Informative) { helper.ci_podx_rules }
    payload = JSON.parse(File.read(File.join(project_dir, '.podx', 'rules_snapshot.json')))

    assert_includes error.message, 'rules ci 失败'
    assert_equal 'fail', payload['status']
    assert_operator payload['missing_count'], :>, 0
  ensure
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_podx_rules_ci_passes_when_gitignore_has_all_rules
    project_dir = Dir.mktmpdir('cocoapods-podx-rules-ci-pass')
    rules = CocoapodsPodx::Rules.local_artifact_gitignore_rules(config_path: File.join(project_dir, 'podx.config.yml'))
    File.write(File.join(project_dir, '.gitignore'), "#{rules.join("\n")}\n")
    helper = rules_command_helper(project_dir)

    helper.ci_podx_rules
    payload = JSON.parse(File.read(File.join(project_dir, '.podx', 'rules_snapshot.json')))

    assert_equal 'pass', payload['status']
    assert_equal 0, payload['missing_count']
  ensure
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_pipeline_runtime_outputs_ci_cd_capability_map
    helper = Class.new do
      include CocoapodsPodx::Commands::GitActions
      include CocoapodsPodx::Commands::PipelineRuntime
    end.new

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      helper.show_pipeline_map
    end

    assert_includes output, '【pipeline 能力地图】'
    assert_includes output, 'podx rules ci'
    assert_includes output, 'podx skill ci strict'
    assert_includes output, 'mgit publish release/x.x.x'
    assert_includes output, 'podx publish doctor'
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_pipeline_runtime_outputs_ci_template
    helper = Class.new do
      include CocoapodsPodx::Commands::GitActions
      include CocoapodsPodx::Commands::PipelineRuntime

      def initialize
        @pod_names = ['ci']
      end
    end.new

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      helper.show_pipeline_map
    end

    assert_includes output, '【pipeline ci 模板】'
    assert_includes output, 'podx rules ci'
    assert_includes output, 'podx skill ci strict'
    assert_includes output, 'podx graph'
    assert_includes output, 'podx pipeline snapshot'
    assert_includes output, 'podx pipeline report'
    assert_includes output, 'podx pipeline gate'
    assert_includes output, '执行 podx rules sync 后重新检查'
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_pipeline_runtime_outputs_main_flow
    helper = Class.new do
      include CocoapodsPodx::Commands::GitActions
      include CocoapodsPodx::Commands::PipelineRuntime

      def initialize
        @pod_names = ['flow']
      end
    end.new

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      helper.show_pipeline_map
    end

    assert_includes output, '【pipeline 主流程】'
    assert_includes output, '开发主流程'
    assert_includes output, '发布主流程'
    assert_includes output, 'podx install / podx update NAME'
    assert_includes output, 'podx publish [pgyer|tf|app]'
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_pipeline_runtime_policy_outputs_effective_publish_gate_strategy
    project_dir = Dir.mktmpdir('cocoapods-podx-pipeline-policy')
    File.write(File.join(project_dir, 'podx.config.yml'), <<~YAML)
      publish_pipeline_gate: true
      publish_pipeline_gate_strategy:
        pgyer: warn
        testflight: strict
        appstore: strict
        framework: off
    YAML
    helper = pipeline_runtime_helper(project_dir, ['policy'])

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      helper.show_pipeline_map
    end

    assert_includes output, '【pipeline policy】'
    assert_match(/\| 蒲公英\s+\| warn/, output)
    assert_includes output, '| TestFlight | strict'
    assert_includes output, '| AppStore   | strict'
    assert_includes output, '| Framework  | off'
    assert_includes output, '告警继续'
    assert_includes output, '失败阻断'
    assert_includes output, '不预检'
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_pipeline_runtime_policy_is_off_when_publish_gate_disabled
    project_dir = Dir.mktmpdir('cocoapods-podx-pipeline-policy-off')
    File.write(File.join(project_dir, 'podx.config.yml'), "publish_pipeline_gate: false\n")
    helper = pipeline_runtime_helper(project_dir, ['policy'])

    rows = helper.pipeline_policy_rows

    assert rows.all? { |row| row[1] == 'off' }
    assert rows.all? { |row| row[3] == '不预检' }
  ensure
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_pipeline_runtime_readiness_combines_policy_and_gate_status
    project_dir = Dir.mktmpdir('cocoapods-podx-pipeline-readiness')
    File.write(File.join(project_dir, 'podx.config.yml'), <<~YAML)
      publish_pipeline_gate: true
      publish_pipeline_gate_strategy:
        pgyer: warn
        testflight: strict
        appstore: strict
        framework: off
    YAML
    helper = pipeline_runtime_helper(project_dir, ['readiness'])

    def helper.pipeline_status_rows
      [['规则门禁', '失败', File.join(project_directory, '.podx', 'rules_snapshot.json')]]
    end

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      helper.show_pipeline_map
    end

    assert_includes output, '【pipeline readiness】'
    assert_match(/\| 蒲公英\s+\| warn\s+\| 可发布\s+\| 告警 1 个/, output)
    assert_includes output, '| TestFlight | strict | 阻断'
    assert_includes output, '| AppStore   | strict | 阻断'
    assert_includes output, '| Framework  | off    | 可发布'
    assert_includes output, '未开启预检'
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_pipeline_runtime_readiness_allows_strict_channels_when_gate_passes
    project_dir = Dir.mktmpdir('cocoapods-podx-pipeline-readiness-pass')
    File.write(File.join(project_dir, 'podx.config.yml'), <<~YAML)
      publish_pipeline_gate: true
    YAML
    helper = pipeline_runtime_helper(project_dir, ['readiness'])

    def helper.pipeline_status_rows
      [['规则门禁', '通过', File.join(project_directory, '.podx', 'rules_snapshot.json')]]
    end

    rows = helper.pipeline_readiness_rows

    assert rows.all? { |row| row[2] == '可发布' }
    assert rows.any? { |row| row[0] == 'TestFlight' && row[3] == '预检通过' }
  ensure
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_pipeline_runtime_writes_ci_script
    project_dir = Dir.mktmpdir('cocoapods-podx-pipeline-script')
    helper = Class.new do
      include CocoapodsPodx::Commands::GitActions
      include CocoapodsPodx::Commands::PipelineRuntime

      def initialize(project_dir)
        @project_directory = project_dir
        @pod_names = ['script']
      end

      def project_directory
        @project_directory
      end
    end.new(project_dir)

    helper.show_pipeline_map
    path = File.join(project_dir, '.podx', 'pipeline_ci.sh')
    content = File.read(path)

    assert File.executable?(path)
    assert_includes content, '#!/bin/sh'
    assert_includes content, 'set -e'
    assert_includes content, 'podx rules ci'
    assert_includes content, 'podx skill ci strict'
    assert_includes content, 'podx graph'
    assert_includes content, 'podx pipeline snapshot'
    assert_includes content, 'podx pipeline report'
    assert_includes content, 'podx pipeline gate'
  ensure
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_pipeline_runtime_doctor_passes_when_script_matches_template
    project_dir = Dir.mktmpdir('cocoapods-podx-pipeline-doctor-pass')
    helper = pipeline_runtime_helper(project_dir, ['script'])
    helper.show_pipeline_map

    helper = pipeline_runtime_helper(project_dir, ['doctor'])
    helper.show_pipeline_map
  ensure
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_pipeline_runtime_doctor_fails_when_script_is_missing
    project_dir = Dir.mktmpdir('cocoapods-podx-pipeline-doctor-fail')
    helper = pipeline_runtime_helper(project_dir, ['doctor'])

    error = assert_raises(Pod::Informative) { helper.show_pipeline_map }

    assert_includes error.message, 'pipeline doctor 失败'
  ensure
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_pipeline_runtime_snapshot_writes_json_payload
    project_dir = Dir.mktmpdir('cocoapods-podx-pipeline-snapshot')
    helper = pipeline_runtime_helper(project_dir, ['script'])
    helper.show_pipeline_map

    helper = pipeline_runtime_helper(project_dir, ['snapshot'])
    helper.show_pipeline_map
    payload = JSON.parse(File.read(File.join(project_dir, '.podx', 'pipeline_snapshot.json')))

    assert_equal 'pass', payload['status']
    assert_equal File.join(project_dir, '.podx', 'pipeline_ci.sh'), payload['script_path']
    assert_equal File.join(project_dir, '.podx', 'pipeline_snapshot.json'), payload['snapshot_path']
    assert payload['stages'].any? { |row| row['command'] == 'podx publish doctor' }
    assert payload['main_flows'].any? { |row| row['flow'] == '开发主流程' && row['command'] == 'mgit status' }
    assert payload['main_flows'].any? { |row| row['flow'] == '发布主流程' && row['command'] == 'podx publish [pgyer|tf|app]' }
    assert payload['ci_steps'].any? { |row| row['command'] == 'podx rules ci' }
    assert payload['ci_steps'].any? { |row| row['command'] == 'podx pipeline gate' }
    assert payload['doctor'].all? { |row| row['status'] == '通过' }
    assert payload['policy'].any? { |row| row['channel'] == 'TestFlight' && row['branch_rule'] == 'release/x.x.x' }
    assert payload['readiness'].any? { |row| row['channel'] == 'TestFlight' && row['readiness'] == '可发布' }
  ensure
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_pipeline_runtime_report_writes_markdown
    project_dir = Dir.mktmpdir('cocoapods-podx-pipeline-report')
    helper = pipeline_runtime_helper(project_dir, ['script'])
    helper.show_pipeline_map

    helper = pipeline_runtime_helper(project_dir, ['report'])
    helper.show_pipeline_map
    markdown = File.read(File.join(project_dir, '.podx', 'pipeline_report.md'))

    assert_includes markdown, '# podx pipeline report'
    assert_includes markdown, '- status: pass'
    assert_includes markdown, '## Main Flow'
    assert_includes markdown, '开发主流程'
    assert_includes markdown, '发布主流程'
    assert_includes markdown, '## CI Steps'
    assert_includes markdown, 'podx rules ci'
    assert_includes markdown, 'podx pipeline gate'
    assert_includes markdown, '## Doctor'
    assert_includes markdown, '脚本内容'
    assert_includes markdown, '## Publish Policy'
    assert_includes markdown, 'TestFlight'
    assert_includes markdown, 'release/x.x.x'
    assert_includes markdown, '## Publish Readiness'
    assert_includes markdown, '可发布'
    assert_includes markdown, '## Capability Map'
    assert_includes markdown, 'podx publish doctor'
  ensure
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_pipeline_runtime_status_summarizes_artifacts
    project_dir = Dir.mktmpdir('cocoapods-podx-pipeline-status')
    FileUtils.mkdir_p(File.join(project_dir, '.podx'))
    File.write(File.join(project_dir, '.podx', 'rules_snapshot.json'), JSON.pretty_generate({ status: 'pass' }))
    File.write(File.join(project_dir, '.podx', 'skill_ci.json'), JSON.pretty_generate({ status: 'fail' }))
    File.write(File.join(project_dir, '.podx', 'pipeline_snapshot.json'), JSON.pretty_generate({ status: 'pass' }))
    File.write(File.join(project_dir, '.podx', 'pipeline_report.md'), '# report')
    helper = pipeline_runtime_helper(project_dir, ['status'])

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      helper.show_pipeline_map
    end

    assert_includes output, '【pipeline status】'
    assert_includes output, '| 规则门禁 | 通过'
    assert_includes output, '| 技能门禁 | 失败'
    assert_includes output, '| 流程快照 | 通过'
    assert_includes output, '| 流程报告 | 通过'
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_pipeline_runtime_status_marks_missing_artifacts
    project_dir = Dir.mktmpdir('cocoapods-podx-pipeline-status-missing')
    helper = pipeline_runtime_helper(project_dir, ['status'])

    rows = helper.pipeline_status_rows

    assert rows.all? { |row| row[1] == '缺失' }
  ensure
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_pipeline_runtime_gate_passes_when_all_artifacts_pass
    project_dir = Dir.mktmpdir('cocoapods-podx-pipeline-gate-pass')
    FileUtils.mkdir_p(File.join(project_dir, '.podx'))
    File.write(File.join(project_dir, '.podx', 'rules_snapshot.json'), JSON.pretty_generate({ status: 'pass' }))
    File.write(File.join(project_dir, '.podx', 'skill_ci.json'), JSON.pretty_generate({ status: 'pass' }))
    File.write(File.join(project_dir, '.podx', 'pipeline_snapshot.json'), JSON.pretty_generate({ status: 'pass' }))
    File.write(File.join(project_dir, '.podx', 'pipeline_report.md'), '# report')
    helper = pipeline_runtime_helper(project_dir, ['gate'])

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      helper.show_pipeline_map
    end

    assert_includes output, '【pipeline gate】'
    assert_includes output, '| 规则门禁 | 通过 | 可继续'
    assert_includes output, '【pipeline gate】通过'
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_pipeline_runtime_gate_fails_with_actionable_suggestion
    project_dir = Dir.mktmpdir('cocoapods-podx-pipeline-gate-fail')
    FileUtils.mkdir_p(File.join(project_dir, '.podx'))
    File.write(File.join(project_dir, '.podx', 'rules_snapshot.json'), JSON.pretty_generate({ status: 'fail' }))
    helper = pipeline_runtime_helper(project_dir, ['gate'])

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      error = assert_raises(Pod::Informative) { helper.show_pipeline_map }
      assert_includes error.message, 'pipeline gate 失败'
    end

    assert_includes output, '| 规则门禁 | 失败 | 执行 podx rules sync && podx rules ci'
    assert_includes output, '| 技能门禁 | 缺失 | 执行 podx skill init 或 podx skill ci strict'
    assert_includes output, '【pipeline gate】失败'
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def pipeline_runtime_helper(project_dir, pod_names)
    Class.new do
      include CocoapodsPodx::Commands::GitActions
      include CocoapodsPodx::Commands::PipelineRuntime

      def initialize(project_dir, pod_names)
        @project_directory = project_dir
        @pod_names = pod_names
      end

      def project_directory
        @project_directory
      end
    end.new(project_dir, pod_names)
  end

  def rules_command_helper(project_dir)
    Class.new do
      include CocoapodsPodx::Commands::GitActions
      include CocoapodsPodx::Commands::GitHooks

      def initialize(project_dir)
        @project_directory = project_dir
      end

      def project_directory
        @project_directory
      end

      def config_path
        File.join(@project_directory, 'podx.config.yml')
      end
    end.new(project_dir)
  end

  def test_mgit_publish_allows_protected_file_commit_only_inside_publish_commit
    publisher = Class.new do
      include CocoapodsPodx::Commands::MgitPublish
    end.new

    ENV.delete('COCOAPODS_PODX_ALLOW_PROTECTED_COMMIT')
    seen = nil
    publisher.with_mgit_publish_protected_commit_allowed do
      seen = ENV['COCOAPODS_PODX_ALLOW_PROTECTED_COMMIT']
    end

    assert_equal 'mgit_publish', seen
    assert_nil ENV['COCOAPODS_PODX_ALLOW_PROTECTED_COMMIT']
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
        %w[仓库 分支 Commit 更新 本地变更],
        [
          helper.git_status_table_row(['main', 'feature/5.14.2_broadcast', 'changed', 'LoginLogic.swift', '/tmp/main', 'bd5ad0', '有更新']),
          helper.git_status_table_row(['NNBussCom', 'feature/5.14.2_broadcast', 'changed', 'NNVoiceRoomViewController.swift', '/tmp/nnbusscom', '258c70', '-']),
          helper.git_status_table_row(['NNApperance', 'feature/5.14.2_broadcast', 'clean', '-', '/tmp/nnapperance', '96bc4c', '-'])
        ]
      )
    end

    assert_includes output, '| Commit'
    assert_includes output, '| 更新'
    assert_includes output, '| 本地变更'
    assert_includes output, 'LoginLogic.swift'
    refute_includes output, 'NNIM/Src/Main/Auth'
    assert_includes output, 'NNVoiceRoomViewController.swift'
    assert_includes output, 'bd5ad0'
    assert_includes output, '有更新'

    table_lines = output.lines.map(&:chomp).select { |line| line.start_with?('|', '+') }
    widths = table_lines.map { |line| helper.git_action_display_width(line) }
    assert_equal 1, widths.uniq.length
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_git_actions_status_update_does_not_fetch_remote
    helper = Class.new do
      include CocoapodsPodx::Commands::GitActions

      def fetch_branch_quietly(_path, _branch)
        raise 'status should not fetch'
      end
    end.new

    assert_equal '-', helper.git_action_update_status('/tmp/not-a-repo', 'develop')
  end

  def test_git_actions_parse_branch_status_from_single_status_command
    helper = Class.new do
      include CocoapodsPodx::Commands::GitActions
    end.new

    parsed = helper.git_action_parse_branch_status('## develop...origin/develop [ahead 2, behind 1]')
    assert_equal 'develop', parsed[:branch]
    assert_equal 2, parsed[:ahead_count]
    assert_equal 1, parsed[:behind_count]

    parsed = helper.git_action_parse_branch_status('## release/5.14.5')
    assert_equal 'release/5.14.5', parsed[:branch]
    assert_nil parsed[:ahead_count]
    assert_equal 0, parsed[:behind_count]
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
    assert_match(/\| NNBussCom\s+\| feature\/5\.14\.2_broadcast \| -\s+\|/, output)
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
        @ahead_counts = {
          main_path => 0,
          component_path => 1
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

      def git_ahead_count(path, _branch)
        @ahead_counts[path]
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

    assert_match(/\| main\s+\| feature\/5\.14\.2_broadcast \| -\s+\|/, output)
    assert_match(/\| NNBasciCommon \| feature\/5\.14\.2_broadcast \| 已推送 \|/, output)
    assert_includes helper.commands, [component_path, ['push', 'origin', 'feature/5.14.2_broadcast']]
    refute_includes helper.commands, [main_path, ['push', 'origin', 'feature/5.14.2_broadcast']]
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_git_actions_commit_edit_allows_protected_main_file
    project_dir = Dir.mktmpdir('cocoapods-podx-commit-edit')
    helper = Class.new do
      include CocoapodsPodx::Commands::GitActions

      attr_reader :commands, :commit_env

      def initialize(project_dir)
        @project_directory = project_dir
        @commit_mode = true
        @dry_run = false
        @commit_message = 'update podfile'
        @protected_edit_files = ['Podfile']
        @commands = []
      end

      def project_directory
        @project_directory
      end

      def commit_targets(_entries)
        [{ name: 'main', path: @project_directory }]
      end

      def git_work_tree?(_path)
        true
      end

      def git_branch_for(_path)
        'develop'
      end

      def git_status_lines(_path)
        [' M Podfile']
      end

      def run_git!(path, *args)
        @commands << [path, args]
        @commit_env = ENV['COCOAPODS_PODX_ALLOW_PROTECTED_COMMIT'] if args.first == 'commit'
        ''
      end
    end.new(project_dir)

    ENV.delete('COCOAPODS_PODX_ALLOW_PROTECTED_COMMIT')
    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |_message = ''| }
    helper.commit_repos([])

    assert_includes helper.commands, [project_dir, ['add', '-A']]
    assert_includes helper.commands, [project_dir, ['commit', '-m', 'update podfile']]
    assert_equal 'mgit_publish', helper.commit_env
    assert_nil ENV['COCOAPODS_PODX_ALLOW_PROTECTED_COMMIT']
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

  def test_mgit_stash_apply_requires_one_repo_name
    Dir.chdir(@project_dir) do
      error = assert_raises(Pod::Informative) do
        CocoapodsPodx::MgitStandalone.new(['stash', 'apply'])
      end
      assert_includes error.message, 'mgit stash apply 必须指定一个仓库'

      error = assert_raises(Pod::Informative) do
        CocoapodsPodx::MgitStandalone.new(['stash', 'apply', 'NNLibrary', 'NNBussCom'])
      end
      assert_includes error.message, 'mgit stash apply 必须指定一个仓库'
    end
  end

  def test_mgit_stash_pop_is_not_supported
    Dir.chdir(@project_dir) do
      error = assert_raises(Pod::Informative) do
        CocoapodsPodx::MgitStandalone.new(['stash', 'pop', 'NNLibrary'])
      end
      assert_includes error.message, 'mgit 不支持 stash pop'
    end
  end

  def test_mgit_stash_help_prints_help_instead_of_treating_help_as_repo
    Dir.chdir(@project_dir) do
      command = CocoapodsPodx::MgitStandalone.new(['stash', 'help'])
      assert command.instance_variable_get(:@help_mode)
      assert command.instance_variable_get(:@stash_mode)
      assert_empty command.instance_variable_get(:@pod_names)
    end
  end

  def test_mgit_stash_apply_single_repo_parses_safely
    Dir.chdir(@project_dir) do
      command = CocoapodsPodx::MgitStandalone.new(['stash', 'apply', 'NNLibrary'])
      assert command.instance_variable_get(:@stash_mode)
      assert command.instance_variable_get(:@stash_apply_mode)
      assert_equal ['NNLibrary'], command.instance_variable_get(:@pod_names)
    end
  end

  def test_git_actions_stash_apply_uses_git_stash_apply
    Dir.mktmpdir('cocoapods-podx-stash-apply') do |path|
      helper = Class.new do
        include CocoapodsPodx::Commands::GitActions

        attr_reader :commands

        def initialize(path)
          @path = path
          @stash_mode = true
          @stash_apply_mode = true
          @pod_names = ['NNLibrary']
          @dry_run = false
          @commands = []
        end

        def commit_targets(_entries)
          [{ name: 'NNLibrary', path: @path }]
        end

        def git_work_tree?(_path); true; end

        def git_branch_for(_path); 'develop'; end

        def git_status_lines(_path); []; end

        def git_stash_lines(_path)
          ['stash@{0}: On develop: mgit stash']
        end

        def run_git!(path, *args)
          @commands << [path, args]
          ''
        end
      end.new(path)

      original_puts = Pod::UI.method(:puts)
      Pod::UI.define_singleton_method(:puts) { |_message = ''| }
      helper.git_action_repos([])

      assert_includes helper.commands, [path, ['stash', 'apply', 'stash@{0}']]
    ensure
      Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
    end
  end

  def test_git_actions_stash_list_is_read_only
    Dir.mktmpdir('cocoapods-podx-stash-list') do |path|
      helper = Class.new do
        include CocoapodsPodx::Commands::GitActions

        def initialize(path)
          @path = path
          @stash_mode = true
          @stash_list_mode = true
          @pod_names = []
          @dry_run = false
        end

        def commit_targets(_entries)
          [{ name: 'main', path: @path }]
        end

        def git_work_tree?(_path); true; end

        def git_branch_for(_path); 'develop'; end

        def git_status_lines(_path); []; end

        def git_stash_lines(_path)
          ['stash@{0}: On develop: mgit stash']
        end
      end.new(path)

      original_puts = Pod::UI.method(:puts)
      Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
      output, = capture_io { helper.git_action_repos([]) }

      assert_includes output, 'stash@{0}: On develop: mgit stash'
    ensure
      Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
    end
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

    helper.instance_variable_set(:@publish_password, '1234')
    params = helper.jenkins_build_params({ branch_param: 'branch', source_param: nil }, 'origin/release/5.14.2', name: 'TestFlight', value: 'TestFlight,', kind: :app)
    assert_equal '1234,', params['VERIFICATION_PASSWORD']
  end

  def test_jenkins_publish_wechat_notify_params
    helper = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish
    end.new
    target = { name: '打 Framework', value: nil, kind: :framework }

    helper.instance_variable_set(:@notify_wechat, 'false')
    params = helper.jenkins_build_params({ branch_param: 'BRANCH', source_param: nil, notify_param: 'WECHAT_NOTIFY' }, 'origin/develop', target)
    assert_equal 'false', params['WECHAT_NOTIFY']

    params = helper.jenkins_build_params({ branch_param: 'BRANCH', source_param: nil, notify_param: 'NO_WECHAT_NOTIFY' }, 'origin/develop', target)
    assert_equal 'true', params['NO_WECHAT_NOTIFY']

    params = helper.jenkins_build_params({ branch_param: 'BRANCH', source_param: nil, notify_param: 'no-wechat-notify' }, 'origin/develop', target)
    assert_equal 'true', params['no-wechat-notify']

    helper.instance_variable_set(:@notify_wechat, 'true')
    params = helper.jenkins_build_params({ branch_param: 'BRANCH', source_param: nil, notify_param: nil }, 'origin/develop', target)
    assert_equal 'true', params['NOTIFY_WECHAT_ON_SUCCESS']

    helper.instance_variable_set(:@notify_wechat, 'bad')
    error = assert_raises(Pod::Informative) do
      helper.jenkins_build_params({ branch_param: 'BRANCH', source_param: nil, notify_param: 'NOTIFY_WECHAT' }, 'origin/develop', target)
    end
    assert_includes error.message, 'notify-wechat'
  end

  def test_jenkins_publish_force_private_pod_update_params
    helper = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish
    end.new
    target = { name: '蒲公英', value: 'Pgyer,', kind: :app }
    profile = { branch_param: 'branch', source_param: nil, notify_param: nil }

    helper.instance_variable_set(:@force_private_pod_update, 'true')
    params = helper.jenkins_build_params(profile, 'origin/develop', target)
    assert_equal 'true', params['FORCE_PRIVATE_POD_UPDATE']

    helper.instance_variable_set(:@force_private_pod_update, 'false')
    params = helper.jenkins_build_params(profile, 'origin/develop', target)
    assert_equal 'false', params['FORCE_PRIVATE_POD_UPDATE']

    helper.instance_variable_set(:@force_private_pod_update, 'bad')
    error = assert_raises(Pod::Informative) do
      helper.jenkins_build_params(profile, 'origin/develop', target)
    end
    assert_includes error.message, 'force-private-pod-update'
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
    assert_includes error.message, '当前分支不是 release/x.x.x'
    assert_includes error.message, 'podx publish tf --branch release/x.x.x'
    assert_includes error.message, '切换到 "release/x.x.x"'

    helper.instance_variable_set(:@publish_branch, 'develop')
    error = assert_raises(Pod::Informative) do
      helper.validate_jenkins_publish_branch!('origin/develop', name: 'TestFlight', value: 'TestFlight,')
    end
    assert_includes error.message, '只能发布 release/x.x.x 分支'

    error = assert_raises(Pod::Informative) do
      helper.validate_jenkins_publish_branch!('origin/release/x.x.x', name: '蒲公英', value: 'Pgyer,')
    end
    assert_includes error.message, '发布分支不能使用示例占位符'
  end

  def test_jenkins_publish_rejects_help_placeholders
    helper = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish
    end.new

    error = assert_raises(Pod::Informative) do
      helper.jenkins_deploy_target('[pgyer|tf|app]')
    end
    assert_includes error.message, '发布渠道不能使用示例占位符'

    helper.instance_variable_set(:@publish_branch, 'release/x.x.x')
    error = assert_raises(Pod::Informative) do
      helper.jenkins_publish_branch
    end
    assert_includes error.message, '发布分支不能使用示例占位符'
  end

  def test_jenkins_publish_rejects_podfile_component_branch_mismatch
    project_dir = Dir.mktmpdir('cocoapods-podx-publish-branch-mismatch')
    File.write(File.join(project_dir, 'Podfile'), "pod 'NNIMManager', :branch => 'feature/5.14.2_broadcast'\n")
    helper = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      attr_accessor :project_dir

      def podfile_path
        File.join(project_dir, 'Podfile')
      end

      def publish_private_repo_names
        %w[NNIMManager NNBussCom]
      end

      def declared_branch_for(name)
        { 'NNIMManager' => 'feature/5.14.2_broadcast', 'NNBussCom' => 'develop' }[name]
      end
    end.new
    helper.project_dir = project_dir

    error = assert_raises(Pod::Informative) do
      helper.validate_publish_podfile_component_branches!('origin/develop')
    end

    assert_includes error.message, 'Podfile 中私有组件分支必须与本次打包分支同名'
    assert_includes error.message, 'NNIMManager: Podfile=feature/5.14.2_broadcast, 打包分支=develop'
    refute_includes error.message, 'NNBussCom'
  ensure
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_jenkins_publish_accepts_podfile_component_branch_with_origin_prefix
    project_dir = Dir.mktmpdir('cocoapods-podx-publish-branch-match')
    File.write(File.join(project_dir, 'Podfile'), "pod 'NNIMManager', :branch => 'develop'\n")
    helper = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish

      attr_accessor :project_dir

      def podfile_path
        File.join(project_dir, 'Podfile')
      end

      def publish_private_repo_names
        %w[NNIMManager]
      end

      def declared_branch_for(_name)
        'origin/develop'
      end
    end.new
    helper.project_dir = project_dir

    helper.validate_publish_podfile_component_branches!('origin/develop')
  ensure
    FileUtils.rm_rf(project_dir) if project_dir
  end

  def test_jenkins_publish_requires_remote_release_branch_for_main_and_components
    helper = Class.new do
      include CocoapodsPodx::Commands::JenkinsPublish
    end.new

    helper.validate_publish_remote_release_branches!(
      'origin/release/5.14.2',
      [
        { repo: 'nnios', branch: 'release/5.14.2', commit: 'abcdef', log: 'ok' },
        { repo: 'NNBussCom', branch: 'release/5.14.2', commit: '123456', log: 'ok' }
      ],
      name: 'TestFlight',
      value: 'TestFlight,'
    )

    error = assert_raises(Pod::Informative) do
      helper.validate_publish_remote_release_branches!(
        'origin/release/5.14.2',
        [
          { repo: 'nnios', branch: 'release/5.14.2', commit: 'abcdef', log: 'ok' },
          { repo: 'NNBussCom', branch: 'release/5.14.2', commit: '-', log: '远端分支不存在或无法获取：release/5.14.2' }
        ],
        name: 'TestFlight',
        value: 'TestFlight,'
      )
    end

    assert_includes error.message, '远端主工程和依赖组件仓库都存在'
    assert_includes error.message, 'NNBussCom release/5.14.2'
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
      { 'name' => 'PODX_TRIGGER_SOURCE' },
      { 'name' => 'NOTIFY_WECHAT_ON_SUCCESS' }
    ]
    app_profile = helper.jenkins_publish_job_profile
    assert_equal :app, app_profile[:kind]
    assert_equal 'pgyer', app_profile[:default_channel]
    assert_equal 'branch', app_profile[:branch_param]
    assert_equal 'PODX_TRIGGER_SOURCE', app_profile[:source_param]
    assert_equal 'NOTIFY_WECHAT_ON_SUCCESS', app_profile[:notify_param]
    helper.instance_variable_set(:@notify_wechat, 'false')
    params = helper.jenkins_build_params(app_profile, 'origin/develop', helper.jenkins_deploy_target('pgyer'))
    assert_equal 'podx publish', params['PODX_TRIGGER_SOURCE']
    assert_equal 'false', params['NOTIFY_WECHAT_ON_SUCCESS']
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

  def test_local_overlay_branch_mismatch_is_printed_in_install_table
    FileUtils.mkdir_p(File.join(@project_dir, 'Development Pods', 'NNLibrary'))
    Dir.chdir(@project_dir) do
      `git init -q`
      `git checkout -b develop >/dev/null 2>&1`
    end
    Dir.chdir(File.join(@project_dir, 'Development Pods', 'NNLibrary')) do
      `git init -q`
      `git checkout -b release/5.14.5 >/dev/null 2>&1`
    end
    File.write(File.join(@project_dir, 'Podfile.overlay'), "pod 'NNLibrary'\n")
    CocoapodsPodx::Runtime.configure(project_directory: @project_dir)

    output = nil
    error = nil
    output = capture_io do
      error = assert_raises(RuntimeError) do
        CocoapodsPodx::Runtime.pod_options_for(name: 'NNLibrary')
      end
    end.first

    assert_includes output, '| NNLibrary'
    assert_includes output, '| 本地'
    assert_includes output, '| release/5.14.5'
    assert_includes output, '| 失败'
    assert_includes error.message, '当前分支为 release/5.14.5'
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

  def test_podx_clean_cleans_cache_and_removes_installed_pod
    FileUtils.mkdir_p(File.join(@project_dir, 'Pods', 'NNRtc'))
    File.write(File.join(@project_dir, 'Pods', 'NNRtc', 'README.md'), 'cached')

    command = Pod::Command::Podx.allocate
    command.instance_variable_set(:@project_directory, @project_dir)
    command.instance_variable_set(:@pod_names, ['NNRtc'])
    command.instance_variable_set(:@dry_run, false)
    cache_names = []
    command.define_singleton_method(:clean_pod_cache) do |name|
      cache_names << name
      '已清理'
    end

    original_puts = Pod::UI.method(:puts)
    Pod::UI.define_singleton_method(:puts) { |message = ''| $stdout.puts(message) }
    output, = capture_io do
      command.send(:clean_pod_cache_and_installed_pods)
    end

    assert_equal ['NNRtc'], cache_names
    refute File.exist?(File.join(@project_dir, 'Pods', 'NNRtc'))
    assert_includes output, '【podx clean 结果】'
    assert_includes output, '| NNRtc | 已清理 | 已删除 NNRtc |'
    assert_includes output, 'clean [done] 1'
  ensure
    Pod::UI.define_singleton_method(:puts, original_puts) if original_puts
  end

  def test_podx_clean_subspec_removes_root_pod_directory
    FileUtils.mkdir_p(File.join(@project_dir, 'Pods', 'JXPagingView'))

    command = Pod::Command::Podx.allocate
    command.instance_variable_set(:@project_directory, @project_dir)
    command.instance_variable_set(:@pod_names, ['JXPagingView/Paging'])
    command.instance_variable_set(:@dry_run, false)
    command.define_singleton_method(:clean_pod_cache) { |_name| '已清理' }

    command.send(:clean_pod_cache_and_installed_pods)

    refute File.exist?(File.join(@project_dir, 'Pods', 'JXPagingView'))
  end

  def test_podx_clean_requires_component_name
    command = Pod::Command::Podx.allocate
    command.instance_variable_set(:@project_directory, @project_dir)
    command.instance_variable_set(:@pod_names, [])
    command.instance_variable_set(:@dry_run, false)

    error = assert_raises(Pod::Informative) do
      command.send(:clean_pod_cache_and_installed_pods)
    end

    assert_includes error.message, '请指定要清理的组件'
  end
end
