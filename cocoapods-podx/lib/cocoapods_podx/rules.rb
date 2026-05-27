require 'yaml'

module CocoapodsPodx
  module Rules
    class Engine
      def initialize(config_path:)
        @config_path = config_path
      end

      def commit_protection
        @commit_protection ||= CommitProtection.new(config: project_config)
      end

      def summaries
        @summaries ||= Summary.new(config: project_config).rows
      end

      private

      def project_config
        return {} if @config_path.to_s.empty? || !File.exist?(@config_path)

        raw = YAML.safe_load(File.read(@config_path), permitted_classes: [], permitted_symbols: [], aliases: false) || {}
        normalize_hash_keys(raw)
      rescue
        {}
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
    end

    class CommitProtection
      DEFAULT_PROTECTED_FILES = %w[Podfile.rb].freeze
      ALLOW_ENV = 'COCOAPODS_PODX_ALLOW_PROTECTED_COMMIT'.freeze
      ALLOW_CONTEXT_MGIT_PUBLISH = 'mgit_publish'.freeze
      HOOK_MARKER_BEGIN = '# >>> cocoapods-podx protected files hook'.freeze
      HOOK_MARKER_END = '# <<< cocoapods-podx protected files hook'.freeze
      POST_MERGE_HOOK_MARKER_BEGIN = '# >>> cocoapods-podx protected files post-merge hook'.freeze
      POST_MERGE_HOOK_MARKER_END = '# <<< cocoapods-podx protected files post-merge hook'.freeze

      attr_reader :config

      def initialize(config:)
        @config = config || {}
      end

      def protected_files
        protected_files_for(scope: :main)
      end

      def protected_files_for(scope:)
        return [] unless scope.to_sym == :main

        files = protected_files_source == '配置' ? configured_protected_files : DEFAULT_PROTECTED_FILES
        files.map(&:strip).reject(&:empty?).uniq
      end

      def protected_files_source
        configured_protected_files.empty? ? '默认' : '配置'
      end

      def configured_protected_files
        Array(config[:protected_commit_files]).map(&:to_s)
      end

      def allow_env
        ALLOW_ENV
      end

      def allow_context
        ALLOW_CONTEXT_MGIT_PUBLISH
      end

      def allow_entries
        ['mgit publish', 'mgit commit -edit']
      end

      def hook_marker_begin
        HOOK_MARKER_BEGIN
      end

      def hook_marker_end
        HOOK_MARKER_END
      end

      def post_merge_hook_marker_begin
        POST_MERGE_HOOK_MARKER_BEGIN
      end

      def post_merge_hook_marker_end
        POST_MERGE_HOOK_MARKER_END
      end
    end

    class Summary
      def initialize(config:)
        @config = config || {}
      end

      def rows
        rows = [commit_protection_row, merge_protection_row]
        rows << publish_branch_row if publish_enabled?
        rows << publish_podfile_branch_row if update_podfile_branch?
        rows << publish_ios_project_version_row if ios_version_enabled?
        rows << app_publish_branch_row
        rows
      end

      private

      attr_reader :config

      def commit_protection_row
        rule = CommitProtection.new(config: config)
        [
          '提交保护',
          rule.protected_files_source,
          rule.protected_files.join(', '),
          'publish/commit-edit'
        ]
      end

      def merge_protection_row
        rule = CommitProtection.new(config: config)
        [
          '合并保护',
          rule.protected_files_source,
          "还原#{rule.protected_files.join(', ')}",
          'pull/merge'
        ]
      end

      def publish_branch_row
        [
          '发布分支',
          '配置',
          "#{publish_base_branch}->#{release_branch_label}",
          'mgit publish'
        ]
      end

      def publish_podfile_branch_row
        [
          'Podfile分支',
          '配置',
          '组件branch->发布分支',
          'mgit publish'
        ]
      end

      def publish_ios_project_version_row
        [
          'iOS版本',
          '配置',
          ios_build_enabled? ? '改Version/Build' : '改Version',
          'mgit publish'
        ]
      end

      def app_publish_branch_row
        [
          '发布渠道',
          '内置',
          'tf/app仅release',
          'podx publish'
        ]
      end

      def publish_enabled?
        !config[:publish_main_repo].to_s.strip.empty? || !Array(config[:publish_repos]).empty?
      end

      def update_podfile_branch?
        config[:publish_update_podfile_branch] == true
      end

      def ios_version_enabled?
        publish_version_config[:type] == 'ios_xcodeproj' && !publish_version_config[:project_file].to_s.strip.empty?
      end

      def ios_build_enabled?
        ios_version_enabled? && publish_version_config[:build_number_strategy] == 'ios_semver'
      end

      def publish_base_branch
        branch = config[:publish_base_branch].to_s.strip
        branch.empty? ? 'develop' : branch
      end

      def release_branch_label
        pattern = publish_version_config[:branch_pattern].to_s
        pattern.include?('release/') ? 'release/x.x.x' : '目标分支'
      end

      def publish_version_config
        raw = config[:publish_version]
        raw.is_a?(Hash) ? raw : {}
      end
    end

    class << self
      def engine(config_path:)
        Engine.new(config_path: config_path)
      end
    end
  end
end
