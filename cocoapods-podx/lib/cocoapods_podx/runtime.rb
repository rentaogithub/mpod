require 'fileutils'
require 'open3'
require 'timeout'
require 'yaml'

module CocoapodsPodx
  module Runtime
    MANAGED_OPTION_KEYS = %i[branch group_name configurations custom_git_target remote_name local_name].freeze
    MANAGED_IDENTITY_OPTION_KEYS = %i[branch group_name custom_git_target remote_name local_name].freeze
    SOURCE_OPTION_KEYS = %i[git path podspec http].freeze

    class PodOverlay
      def initialize
        @pods = {}
      end

      def pod(name = nil, *args)
        return if name.nil? || name.to_s.empty?

        pod_options = args.last.is_a?(Hash) ? args.last.dup : {}
        @pods[name] = pod_options

        raw_name = name.include?('/') ? name.split('/').first : name
        @pods[raw_name] ||= pod_options
      end

      alias npod pod

      def config_for(name)
        return nil if name.nil?

        @pods[name] || @pods[name.include?('/') ? name.split('/').first : name]
      end

      def raw_pods
        @pods
      end
    end

    DEVELOPMENT_PODS_DIR = 'Development Pods'.freeze
    CONFIG_FILE_NAME = 'podx.config.yml'.freeze
    LEGACY_CONFIG_FILE_NAME = 'Podfile.overlay.config.yml'.freeze

    class << self
      attr_writer :project_directory, :config_path

      def configure(project_directory:, config_path: nil)
        @project_directory = File.expand_path(project_directory)
        @config_path = config_path && File.expand_path(config_path)
        @overlay = nil
        @supported_overlay_names = nil
        @managed_pod_definitions = nil
        @project_config = nil
        @install_table_started = false
        @install_table_footer_printed = false
        @install_table_footer_registered = false
        @install_table_has_updates = false
      end

      def private_source
        project_config[:private_source]
      end

      def git_base_url
        project_config[:git_base_url]
      end

      def managed_pod_definition(name)
        managed_pod_definitions[raw_pod_name(name)]
      end

      def managed_pod?(name)
        !managed_pod_definition(name).nil?
      end

      def managed_options?(options)
        !extract_managed_options(options).nil?
      end

      def managed_pod_entries
        managed_pod_definitions.map do |name, definition|
          definition.merge(name: name)
        end
      end

      def local_repo_folder_name_for(name)
        definition = managed_pod_definition(name) || {}
        identifier = if definition[:group_name] && definition[:group_name] != target_name && definition[:group_name] != 'nn_ios'
          definition[:group_name]
        else
          raw_pod_name(name)
        end
        definition[:local_name] || identifier.downcase
      end

      def remote_repo_url_for(name)
        definition = managed_pod_definition(name)
        if definition
          raw_name = raw_pod_name(name)
          group_name = definition[:group_name] || target_name
          remote_name = definition[:remote_name] || raw_name
          custom_git_target = definition[:custom_git_target]
        else
          group_name = raw_pod_name(name)
          group_definition = managed_pod_definitions.values.find { |item| item[:group_name] == group_name }
          raise "未找到 #{name} 对应的内部组件 pod 声明" if group_definition.nil?

          remote_name = group_name
          custom_git_target = group_definition[:custom_git_target]
        end

        remote_git_url(group_name: group_name, raw_name: remote_name, custom_git_target: custom_git_target)
      end

      def pod_options_for(name:, explicit_options: {})
        definition = extract_managed_options(explicit_options) || managed_pod_definition(name)
        return explicit_options unless definition

        definition = definition.dup
        definition[:name] = raw_pod_name(name)
        definition[:group_name] ||= target_name
        definition[:configurations] = definition[:configurations] || []
        definition[:inhibit_warnings] = explicit_options.key?(:inhibit_warnings) ? explicit_options[:inhibit_warnings] : false
        definition[:custom_git_target] = definition[:custom_git_target] || explicit_options[:custom_git_target]
        overlay_pod(**definition)
      end

      def extract_managed_options(options)
        return nil unless options.is_a?(Hash)
        return nil if (SOURCE_OPTION_KEYS & options.keys).any?
        return nil if (MANAGED_IDENTITY_OPTION_KEYS & options.keys).empty?

        {
          branch: options[:branch],
          group_name: options[:group_name],
          configurations: options[:configurations],
          custom_git_target: options[:custom_git_target],
          remote_name: options[:remote_name],
          local_name: options[:local_name],
        }.compact
      end

      def strip_managed_options(options)
        return {} unless options.is_a?(Hash)

        options.reject { |key, _| MANAGED_OPTION_KEYS.include?(key) }
      end

      def overlay_pod(name:, group_name: 'nn_ios', tag: '', branch: nil, custom_git_target: nil, remote_name: nil, local_name: nil, configurations: [], inhibit_warnings: false)
        ensure_configured!

        declared_branch = branch
        declared_tag = tag
        overlay_config = overlay_config_for(name: name, group_name: group_name)
        expected_branch = main_app_branch || resolved_branch(declared_branch, declared_tag)
        validate_overlay_config!(name: name, overlay_config: overlay_config)
        use_local = !overlay_config.nil?

        branch = resolved_branch(branch, tag)
        raw_name = raw_pod_name(name)
        remote_name = remote_name || raw_name
        folder_name = local_name || local_repo_folder_name(group_name: group_name, raw_name: raw_name)

        if use_local || jenkins_local_pod(folder_name)
          local_path = jenkins_local_pod(folder_name) ? "./#{folder_name}" : "./#{DEVELOPMENT_PODS_DIR}/#{folder_name}"
          local_repo_path = File.expand_path(local_path, project_directory)
          ensure_local_repo_exists!(
            name: name,
            local_repo_path: local_repo_path,
            expected_branch: expected_branch,
            group_name: group_name,
            remote_name: remote_name,
            custom_git_target: custom_git_target
          ) unless jenkins_local_pod(folder_name)
          current_branch = current_git_branch(local_repo_path)
          display_branch = current_branch || '-'
          local_commit = local_branch_commit_hash(local_repo_path, display_branch)
          branch_error = local_pod_branch_error(name: name, local_repo_path: local_repo_path, expected_branch: expected_branch)
          if branch_error
            print_install_dependency_row(
              name: name,
              source: '本地',
              branch: display_branch,
              commit: local_commit,
              update: local_repo_update_status(local_repo_path, display_branch),
              status: '失败'
            )
            raise branch_error
          end

          print_install_dependency_row(
            name: name,
            source: '本地',
            branch: display_branch,
            commit: local_commit,
            update: local_repo_update_status(local_repo_path, display_branch)
          )
          return { :path => local_path, :inhibit_warnings => inhibit_warnings }
        end

        if tag.include?('develop') || tag.include?('feature/') || tag.include?('release/')
          branch = tag
        end

        url = remote_git_url(group_name: group_name, raw_name: remote_name, custom_git_target: custom_git_target)
        print_install_dependency_row(
          name: name,
          source: '远端',
          branch: branch,
          commit: remote_branch_commit_hash(url, branch),
          update: '-'
        )
        {
          :git => url,
          :branch => branch,
          :configurations => configurations,
          :inhibit_warnings => inhibit_warnings
        }
      end

      def podfile_supported_overlay_names
        return @supported_overlay_names if @supported_overlay_names

        names = []
        managed_pod_definitions.each do |name, definition|
          if definition[:group_name] && definition[:group_name] != target_name && definition[:group_name] != 'nn_ios'
            names << definition[:group_name]
          else
            names << name
          end
        end
        @supported_overlay_names = names.uniq
      end

      def config
        project_config
      end

      private

      def ensure_configured!
        return if @project_directory

        raise 'CocoapodsPodx::Runtime 未配置，请先调用 CocoapodsPodx::Runtime.configure(...)'
      end

      def project_directory
        @project_directory
      end

      def target_name
        project_config[:target_name] || 'pods'
      end

      def config_path
        return @config_path if @config_path

        preferred = File.join(project_directory, CONFIG_FILE_NAME)
        return preferred if File.exist?(preferred)

        legacy = File.join(project_directory, LEGACY_CONFIG_FILE_NAME)
        return legacy if File.exist?(legacy)

        preferred
      end

      def project_config
        return @project_config if @project_config

        unless File.exist?(config_path)
          raise "未找到 podx 配置文件：#{config_path}"
        end

        raw = YAML.safe_load(File.read(config_path), permitted_classes: [], permitted_symbols: [], aliases: false) || {}
        @project_config = normalize_hash_keys(raw)
      end

      def normalize_hash_keys(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, nested_value), memo|
            memo[key.to_sym] = normalize_hash_keys(nested_value)
          end
        when Array
          value.map { |item| normalize_hash_keys(item) }
        else
          value
        end
      end

      def managed_pod_definitions
        return @managed_pod_definitions if @managed_pod_definitions

        definitions = {}
        content = File.exist?(podfile_path) ? File.read(podfile_path) : ''
        content.each_line do |line|
          parsed = parse_managed_pod_line(line)
          next if parsed.nil?

          definitions[parsed[:name]] = parsed.reject { |key, _| key == :name }
        end
        @managed_pod_definitions = definitions
      end

      def parse_managed_pod_line(line)
        match = line.match(/^\s*(npod|pod)\s+['"]([^'"]+)['"]\s*(?:,\s*(.*))?$/)
        return nil if match.nil?

        command = match[1]
        name = match[2]
        option_source = match[3].to_s
        return nil if command == 'pod' && source_option_source?(option_source)
        return nil if command == 'pod' && !managed_option_source?(option_source)

        branch = extract_option(option_source, 'branch')
        group_name = extract_option(option_source, 'group_name')
        custom_git_target = extract_option(option_source, 'custom_git_target')
        remote_name = extract_option(option_source, 'remote_name')
        local_name = extract_option(option_source, 'local_name')
        configurations = extract_array_option(option_source, 'configurations')

        {
          name: name,
          branch: branch,
          group_name: group_name,
          custom_git_target: custom_git_target,
          remote_name: remote_name,
          local_name: local_name,
          configurations: configurations,
        }.compact
      end

      def managed_option_source?(source)
        MANAGED_IDENTITY_OPTION_KEYS.any? do |key|
          source.match?(/(?:#{Regexp.escape(key.to_s)}\s*:|:#{Regexp.escape(key.to_s)}\s*=>)/)
        end
      end

      def source_option_source?(source)
        SOURCE_OPTION_KEYS.any? do |key|
          source.match?(/(?:#{Regexp.escape(key.to_s)}\s*:|:#{Regexp.escape(key.to_s)}\s*=>)/)
        end
      end

      def podfile_path
        File.join(project_directory, 'Podfile')
      end

      def overlay_path
        File.join(project_directory, 'Podfile.overlay')
      end

      def load_overlay
        return @overlay if @overlay

        overlay = PodOverlay.new
        if File.exist?(overlay_path)
          overlay.instance_eval(File.read(overlay_path), overlay_path)
          validate_overlay_pod_names!(overlay)
          puts "【podx install】Podfile.overlay: #{overlay_path}"
        end
        @overlay = overlay
      end

      def overlay_pod_config(name)
        load_overlay.config_for(name)
      end

      def overlay_config_for(name:, group_name:)
        config = overlay_pod_config(name)
        return config unless config.nil?
        return nil if group_name.nil? || group_name == 'nn_ios' || group_name == target_name

        overlay_pod_config(group_name)
      end

      def validate_overlay_pod_names!(overlay)
        overlay_entries = overlay.raw_pods
        invalid_names = overlay_entries.keys.uniq.reject { |name| podfile_supported_overlay_names.include?(name) }
        return if invalid_names.empty?

        invalid_names.each { |name| overlay_entries.delete(name) }
        puts "warning: Podfile.overlay 中以下组件未在主 Podfile 的内部组件 pod 声明中找到，已忽略：#{invalid_names.join(', ')}"
      end

      def validate_overlay_config!(name:, overlay_config:)
        return if overlay_config.nil?
        return if overlay_config.empty?

        raise <<~MSG
          Podfile.overlay 中 #{name} 只需写成 `pod '#{name}'`；不要再写 localWork、branch 或其他参数。
        MSG
      end

      def resolved_branch(branch, tag)
        branch = 'main' if branch.nil?
        return tag if !tag.nil? && (tag.include?('develop') || tag.include?('feature/') || tag.include?('release/'))

        branch
      end

      def print_install_dependency_row(name:, source:, branch:, commit:, update: '-', status: '正常')
        start_install_dependency_table
        widths = install_dependency_table_widths
        puts format_install_table_row([name, source, branch, commit, update, status], widths)
      end

      def start_install_dependency_table
        return if @install_table_started

        @install_table_started = true
        widths = install_dependency_table_widths
        separator = install_table_separator(widths)
        puts '【podx install】依赖来源'
        puts separator
        puts format_install_table_row(%w[组件 来源 分支 Commit 更新 状态], widths)
        puts separator
        print_install_main_repo_row(widths)
        register_install_dependency_table_footer
      end

      def install_dependency_table_widths
        [18, 4, 24, 6, 6, 4]
      end

      def print_install_main_repo_row(widths)
        branch = current_git_branch(project_directory) || '-'
        commit = local_branch_commit_hash(project_directory, branch)
        update = local_repo_update_status(project_directory, branch)
        puts format_install_table_row(['主仓库', '本地', branch, commit, update, '正常'], widths)
      end

      def register_install_dependency_table_footer
        return if @install_table_footer_registered

        @install_table_footer_registered = true
        at_exit { print_install_dependency_table_footer }
      end

      def print_install_dependency_table_footer
        return unless @install_table_started
        return if @install_table_footer_printed

        @install_table_footer_printed = true
        puts install_table_separator(install_dependency_table_widths)
        puts '【podx install】提示 使用mgit pull命令更新代码' if @install_table_has_updates
      end

      def install_table_separator(widths)
        "+#{widths.map { |width| '-' * (width + 2) }.join('+')}+"
      end

      def format_install_table_row(values, widths)
        "| #{values.each_with_index.map { |value, index| pad_install_table_value(truncate_install_table_value(value, widths[index]), widths[index]) }.join(' | ')} |"
      end

      def truncate_install_table_value(value, max_width)
        text = value.to_s
        suffix = '...'
        return text if install_table_display_width(text) <= max_width
        return suffix[0, max_width] if max_width <= install_table_display_width(suffix)

        target_width = max_width - install_table_display_width(suffix)
        result = +''
        width = 0
        text.each_char do |char|
          char_width = install_table_display_width(char)
          break if width + char_width > target_width

          result << char
          width += char_width
        end
        "#{result}#{suffix}"
      end

      def pad_install_table_value(value, width)
        text = value.to_s
        text + (' ' * [width - install_table_display_width(text), 0].max)
      end

      def install_table_display_width(value)
        value.to_s.each_char.sum { |char| install_table_display_char_width(char) }
      end

      def install_table_display_char_width(char)
        code = char.ord
        return 0 if code.zero?
        return 0 if (0x0300..0x036F).cover?(code)
        return 0 if (0x1AB0..0x1AFF).cover?(code)
        return 0 if (0x1DC0..0x1DFF).cover?(code)
        return 0 if (0x20D0..0x20FF).cover?(code)
        return 0 if (0xFE00..0xFE0F).cover?(code)
        return 0 if (0xFE20..0xFE2F).cover?(code)
        return 2 if install_table_wide_display_char?(code)

        1
      end

      def install_table_wide_display_char?(code)
        [
          (0x1100..0x115F),
          (0x2329..0x232A),
          (0x2E80..0xA4CF),
          (0xAC00..0xD7A3),
          (0xF900..0xFAFF),
          (0xFE10..0xFE19),
          (0xFE30..0xFE6F),
          (0xFF00..0xFF60),
          (0xFFE0..0xFFE6),
          (0x1F300..0x1FAFF),
        ].any? { |range| range.cover?(code) }
      end

      def raw_pod_name(name)
        name = name.to_s
        name.include?('/') ? name.split('/').first : name
      end

      def extract_option(source, option_name)
        match = source.match(/(?:#{Regexp.escape(option_name)}\s*:|:#{Regexp.escape(option_name)}\s*=>)\s*['"]([^'"]+)['"]/)
        match && match[1]
      end

      def extract_array_option(source, option_name)
        match = source.match(/(?:#{Regexp.escape(option_name)}\s*:|:#{Regexp.escape(option_name)}\s*=>)\s*\[([^\]]*)\]/)
        return [] if match.nil?

        match[1].scan(/['"]([^'"]+)['"]/).flatten
      end

      def local_repo_folder_name(group_name:, raw_name:)
        definition = managed_pod_definition(raw_name) || {}
        return definition[:local_name] if definition[:local_name]

        if group_name == 'nn_ios' || group_name == target_name
          raw_name.downcase
        else
          group_name.downcase
        end
      end

      def remote_git_url(group_name:, raw_name:, custom_git_target:)
        base = git_base_url
        raise 'overlay 配置缺少 git_base_url' if base.nil? || base.empty?

        if group_name == 'nn_ios' || group_name == target_name
          "#{base}/#{group_name}/#{raw_name.downcase}.git"
        elsif custom_git_target.nil?
          "#{base}/#{target_name}/#{group_name.downcase}.git"
        else
          "#{base}/#{custom_git_target}/#{group_name.downcase}.git"
        end
      end

      def local_branch_commit_hash(repo_path, branch)
        stdout, status = Open3.capture2e('git', '-C', repo_path, 'rev-parse', '--short=6', branch.to_s)
        return stdout.strip if status.success? && !stdout.strip.empty?

        '-'
      rescue StandardError
        '-'
      end

      def remote_branch_commit_hash(url, branch)
        return '-' if url.to_s.empty? || branch.to_s.empty?

        timeout = (ENV['COCOAPODS_PODX_INSTALL_COMMIT_TIMEOUT'] || '3').to_f
        stdout, status = Timeout.timeout(timeout) do
          Open3.capture2e('git', 'ls-remote', url, "refs/heads/#{branch}")
        end
        return '-' unless status.success?

        hash = stdout.to_s.split(/\s+/).first.to_s
        hash.empty? ? '-' : hash[0, 6]
      rescue StandardError
        '-'
      end

      def local_repo_update_status(repo_path, branch)
        return '-' unless File.directory?(repo_path)
        return '-' if branch.to_s.empty? || branch.to_s == '-'
        return '-' unless local_repo_git_work_tree?(repo_path)

        timeout = (ENV['COCOAPODS_PODX_INSTALL_COMMIT_TIMEOUT'] || '3').to_f
        _fetch_output, fetch_status = Timeout.timeout(timeout) do
          Open3.capture2e('git', '-C', repo_path, 'fetch', 'origin', branch.to_s)
        end
        return '未知' unless fetch_status.success?

        stdout, status = Timeout.timeout(timeout) do
          Open3.capture2e('git', '-C', repo_path, 'rev-list', '--count', "HEAD..refs/remotes/origin/#{branch}")
        end
        return '未知' unless status.success?

        if stdout.to_i.positive?
          @install_table_has_updates = true
          '有更新'
        else
          '无更新'
        end
      rescue StandardError
        '未知'
      end

      def local_repo_git_work_tree?(repo_path)
        _stdout, status = Open3.capture2e('git', '-C', repo_path, 'rev-parse', '--is-inside-work-tree')
        status.success?
      rescue StandardError
        false
      end

      def current_git_branch(repo_path)
        return nil unless File.directory?(repo_path)

        Dir.chdir(repo_path) do
          branch = `git branch --show-current 2>/dev/null`.strip
          return nil if branch.empty?

          branch
        end
      end

      def main_app_branch
        current_git_branch(project_directory) || current_git_branch(Dir.pwd)
      end

      def ensure_local_repo_exists!(name:, local_repo_path:, expected_branch:, group_name:, remote_name:, custom_git_target:)
        return if File.directory?(local_repo_path)

        url = remote_git_url(group_name: group_name, raw_name: remote_name, custom_git_target: custom_git_target)
        FileUtils.mkdir_p(File.dirname(local_repo_path))
        stdout, status = Open3.capture2e('git', 'clone', '--branch', expected_branch, url, local_repo_path)
        return if status.success?

        raise <<~MSG
          本地组件 #{name} 路径 #{local_repo_path} 不存在，自动 clone 失败。
          远端仓库：#{url}
          期望分支：#{expected_branch}
          #{stdout.strip}
        MSG
      end

      def local_pod_branch_error(name:, local_repo_path:, expected_branch:)
        current_branch = current_git_branch(local_repo_path)
        return nil if current_branch == expected_branch

        if current_branch.nil?
          return <<~MSG
            本地组件 #{name} 路径 #{local_repo_path} 未检测到 git 当前分支，期望分支为 #{expected_branch}。
            请先执行 `podx update #{name}` 修复本地仓库后，再执行 pod install。
          MSG
        end

        <<~MSG
          本地组件 #{name} 当前分支为 #{current_branch}，与期望分支 #{expected_branch} 不一致。
          请先执行 `podx update #{name}` 对齐分支后，再执行 pod install。
        MSG
      end

      def is_jenkins
        File.directory?('/Users/aaa/ios_build_pods')
      end

      def jenkins_local_pod(name)
        return false unless is_jenkins

        current_dir = File.expand_path('../../..', __FILE__)
        File.directory?(File.join(current_dir, name))
      end
    end
  end
end
