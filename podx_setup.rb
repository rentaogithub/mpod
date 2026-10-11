require 'yaml'

module PodxSetup
  PROJECT_DIRECTORY = File.expand_path('..', __dir__)
  CONFIG_PATH = File.join(PROJECT_DIRECTORY, 'podx.config.yml')
  LEGACY_CONFIG_PATH = File.join(PROJECT_DIRECTORY, 'Podfile.overlay.config.yml')
  MANAGED_OPTION_KEYS = %i[branch group_name configurations custom_git_target remote_name local_name].freeze
  MANAGED_IDENTITY_OPTION_KEYS = %i[branch group_name custom_git_target remote_name local_name].freeze
  SOURCE_OPTION_KEYS = %i[git path podspec http].freeze

  class << self
    attr_reader :plugin_loaded

    def load_plugin
      require 'cocoapods-podx'
      @plugin_loaded = true
    rescue LoadError
      install_plugin
      Gem.clear_paths if defined?(Gem)
      begin
        require 'cocoapods-podx'
        @plugin_loaded = true
      rescue LoadError
        @plugin_loaded = false
        warn 'warning: cocoapods-podx 不可用，已退化为 CocoaPods 远端依赖模式。'
      end
    end

    def install_plugin
      podx_install_script = File.expand_path('cocoapods-podx.sh', __dir__)
      unless File.exist?(podx_install_script)
        warn "warning: 未找到 cocoapods-podx 安装脚本：#{podx_install_script}"
        return
      end

      puts '未检测到 cocoapods-podx，正在自动安装...'
      system('/bin/sh', podx_install_script, 'install')
    end

    def configure
      if plugin_loaded
        CocoapodsPodx::Runtime.configure(project_directory: PROJECT_DIRECTORY)
      elsif defined?(Pod::Podfile::DSL)
        Pod::Podfile::DSL.prepend(FallbackDSLPatch)
      end
    end

    def private_source
      if plugin_loaded
        CocoapodsPodx::Runtime.private_source
      else
        config[:private_source]
      end
    end

    def fallback_pod_options(name:, explicit_options:)
      return nil unless managed_options?(explicit_options)

      raw_name = raw_pod_name(name)
      branch = explicit_options[:branch] || 'main'
      configurations = explicit_options[:configurations] || []
      inhibit_warnings = explicit_options.key?(:inhibit_warnings) ? explicit_options[:inhibit_warnings] : false

      {
        :git => remote_git_url(
          raw_name: explicit_options[:remote_name] || raw_name,
          group_name: explicit_options[:group_name] || target_name,
          custom_git_target: explicit_options[:custom_git_target]
        ),
        :branch => branch,
        :configurations => configurations,
        :inhibit_warnings => inhibit_warnings
      }
    end

    def strip_managed_options(options)
      options.reject { |key, _| MANAGED_OPTION_KEYS.include?(key) }
    end

    private

    def config
      @config ||= begin
        path = File.exist?(CONFIG_PATH) ? CONFIG_PATH : LEGACY_CONFIG_PATH
        raw = File.exist?(path) ? YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false) : {}
        normalize_hash_keys(raw || {})
      end
    end

    def normalize_hash_keys(value)
      case value
      when Hash
        value.each_with_object({}) { |(key, nested_value), memo| memo[key.to_sym] = normalize_hash_keys(nested_value) }
      when Array
        value.map { |item| normalize_hash_keys(item) }
      else
        value
      end
    end

    def target_name
      config[:target_name] || 'pods'
    end

    def git_base_url
      config[:git_base_url] || ''
    end

    def managed_options?(options)
      return false unless options.is_a?(Hash)
      return false if (SOURCE_OPTION_KEYS & options.keys).any?

      (MANAGED_IDENTITY_OPTION_KEYS & options.keys).any?
    end

    def raw_pod_name(name)
      name = name.to_s
      name.include?('/') ? name.split('/').first : name
    end

    def remote_git_url(raw_name:, group_name:, custom_git_target:)
      if group_name == 'app_ios' || group_name == target_name
        "#{git_base_url}/#{group_name}/#{raw_name.downcase}.git"
      elsif custom_git_target.nil?
        "#{git_base_url}/#{target_name}/#{group_name.downcase}.git"
      else
        "#{git_base_url}/#{custom_git_target}/#{group_name.downcase}.git"
      end
    end
  end

  module FallbackDSLPatch
    def pod(name = nil, *requirements)
      has_options = requirements.last.is_a?(Hash)
      explicit_options = has_options ? requirements.pop.dup : {}
      fallback_options = PodxSetup.fallback_pod_options(name: name, explicit_options: explicit_options)

      if fallback_options
        requirements << fallback_options.merge(PodxSetup.strip_managed_options(explicit_options))
      else
        requirements << explicit_options if has_options
      end

      super(name, *requirements)
    end

    def npod(name = nil, *requirements)
      pod(name, *requirements)
    end
  end
end

PodxSetup.load_plugin
PodxSetup.configure

def private_source
  PodxSetup.private_source
end
