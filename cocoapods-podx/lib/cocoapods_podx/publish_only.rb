require 'rubygems'
require_relative 'runtime'
require_relative 'commands/jenkins_publish'

module Pod
  class Informative < StandardError; end unless const_defined?(:Informative)

  module UI
    def self.puts(message = '')
      Kernel.puts(message)
    end
  end unless const_defined?(:UI)
end unless defined?(Pod)

module CocoapodsPodx
  class PublishOnly
    include CocoapodsPodx::Commands::JenkinsPublish

    def self.run(argv)
      new(argv).run
    rescue Pod::Informative => e
      warn "[!] #{e.message}"
      exit 1
    rescue => e
      warn "[!] #{e.message}"
      exit 1
    end

    def initialize(argv)
      @project_directory = Dir.pwd
      @pod_names = []
      @dry_run = false
      parse_arguments(argv)
    end

    def run
      if @jenkins_fix_mode
        @jenkins_log_build = @pod_names.first
        fix_jenkins_build
      elsif @jenkins_history_mode
        show_jenkins_build_history
      elsif @jenkins_doctor_mode
        @jenkins_log_build = @pod_names.first
        doctor_jenkins_build
      elsif @jenkins_log_mode
        @jenkins_log_build = @pod_names.first
        show_jenkins_build_log
      else
        publish_to_jenkins
      end
    end

    def project_directory
      @project_directory
    end

    def podfile_path
      configure_runtime!
      File.join(project_directory, 'Podfile')
    end

    def main_app_branch
      git_branch_for(project_directory) || git_branch_for(Dir.pwd)
    end

    private

    def configure_runtime!
      return if @runtime_configured

      CocoapodsPodx::Runtime.configure(project_directory: project_directory)
      @runtime_configured = true
    end

    def parse_arguments(argv)
      pending_option = nil
      seen_publish = false
      args = argv.dup
      until args.empty?
        arg = args.shift
        if pending_option
          assign_option(pending_option, arg)
          pending_option = nil
          next
        end

        case arg
        when 'dry-run'
          @dry_run = true
        when 'publish'
          seen_publish = true
          next
        when 'log', 'logs'
          if seen_publish
            @jenkins_log_mode = true
            next
          end

          @pod_names << arg
        when 'history', 'hist', 'recent', 'list'
          if seen_publish
            @jenkins_history_mode = true
            next
          end

          @pod_names << arg
        when 'doctor', 'diagnose'
          if seen_publish
            @jenkins_doctor_mode = true
            next
          end

          @pod_names << arg
        when 'fix'
          if seen_publish
            @jenkins_fix_mode = true
            next
          end

          @pod_names << arg
        when '--job', '--jenkins-job', '--jenkins-url', '--branch', '--publish-branch', '--publish-password', '--notify-wechat', '--lines', '--limit', '--fix-job'
          pending_option = arg
        when '--force-private-pod-update'
          if !args.empty? && !args.first.start_with?('-') && args.first.match?(/\A(?:true|false|1|0|yes|no|y|n|on|off|enable|disable|enabled|disabled)\z/i)
            @force_private_pod_update = args.shift
          else
            @force_private_pod_update = 'true'
          end
        when '--no-force-private-pod-update'
          @force_private_pod_update = 'false'
        when '--pipeline-gate'
          @publish_pipeline_gate = true
        when '--no-pipeline-gate'
          @skip_publish_pipeline_gate = true
        when '--no-publish-lock'
          @skip_publish_lock = true
        when '--no-wechat-notify'
          @notify_wechat = 'false'
        when '--no-hermes'
          @jenkins_hermes_analysis = false
        when '--yes'
          @assume_yes = true
        when /\A--job=(.+)\z/
          @jenkins_job = Regexp.last_match(1)
        when /\A--jenkins-job=(.+)\z/
          @jenkins_job = Regexp.last_match(1)
        when /\A--jenkins-url=(.+)\z/
          @jenkins_url = Regexp.last_match(1)
        when /\A--branch=(.+)\z/
          @publish_branch = Regexp.last_match(1)
        when /\A--publish-branch=(.+)\z/
          @publish_branch = Regexp.last_match(1)
        when /\A--publish-password=(.+)\z/
          @publish_password = Regexp.last_match(1)
        when /\A--notify-wechat=(.+)\z/
          @notify_wechat = Regexp.last_match(1)
        when /\A--force-private-pod-update=(.+)\z/
          @force_private_pod_update = Regexp.last_match(1)
        when /\A--lines=(.+)\z/
          @jenkins_log_lines = Regexp.last_match(1)
        when /\A--limit=(.+)\z/
          @jenkins_history_limit = Regexp.last_match(1)
        when /\A--fix-job=(.+)\z/
          @jenkins_fix_job = Regexp.last_match(1)
        when '--dry-run'
          @dry_run = true
        when '--help', '-h', 'help'
          print_help
          exit 0
        when /\A-/
          raise Pod::Informative, "publish-only 模式不支持参数：#{arg}"
        else
          @pod_names << arg
        end
      end

      raise Pod::Informative, "缺少参数值：#{pending_option}" if pending_option
      @jenkins_hermes_analysis = true if @jenkins_hermes_analysis.nil?
    end

    def assign_option(option, value)
      case option
      when '--job', '--jenkins-job'
        @jenkins_job = value
      when '--jenkins-url'
        @jenkins_url = value
      when '--branch', '--publish-branch'
        @publish_branch = value
      when '--publish-password'
        @publish_password = value
      when '--notify-wechat'
        @notify_wechat = value
      when '--lines'
        @jenkins_log_lines = value
      when '--limit'
        @jenkins_history_limit = value
      when '--fix-job'
        @jenkins_fix_job = value
      end
    end

    def declared_managed_pod_branches
      configure_runtime!
      @declared_managed_pod_branches ||= begin
        branches = {}
        CocoapodsPodx::Runtime.managed_pod_entries.each do |entry|
          next if entry[:group_name] && entry[:group_name] != 'nn_ios'

          branches[entry[:name]] = entry[:branch] if entry[:branch]
        end
        branches
      end
    end

    def declared_biz_group_branches
      configure_runtime!
      @declared_biz_group_branches ||= begin
        branches = {}
        CocoapodsPodx::Runtime.managed_pod_entries.each do |entry|
          group_name = entry[:group_name]
          next if group_name.nil? || group_name == 'nn_ios'

          branches[group_name] ||= entry[:branch] if entry[:branch]
        end
        branches
      end
    end

    def declared_branch_for(name)
      declared_managed_pod_branches[name] || declared_biz_group_branches[name]
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

    def print_help
      Pod::UI.puts <<~HELP
        当前环境:
          publish-only 模式，未依赖 CocoaPods

        可用命令:
          podx publish --job JOB [OPTIONS]
          podx publish history [N] --job JOB [OPTIONS]
          podx publish log [BUILD] --job JOB [OPTIONS]
          podx publish doctor [BUILD] --job JOB [OPTIONS]
          podx publish fix [BUILD] --job JOB [OPTIONS]
          podx dry-run publish --job JOB [OPTIONS]

        示例:
          podx publish --job nnrtc-ios-build --branch develop
          podx dry-run publish --job nnrtc-ios-build --branch develop

        Options:
          --branch BRANCH
          --job JOB
          --jenkins-url URL
          --publish-password PASSWORD
          --notify-wechat BOOL
          --no-wechat-notify
          --force-private-pod-update [BOOL]
          --no-force-private-pod-update
          --pipeline-gate
          --no-pipeline-gate
          --no-publish-lock
          --lines N
          --limit N
          --no-hermes
          --yes
          --fix-job JOB
      HELP
    end
  end
end
