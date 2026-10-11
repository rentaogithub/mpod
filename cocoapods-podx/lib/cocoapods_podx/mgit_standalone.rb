require 'fileutils'
require 'open3'
require 'rubygems'
require_relative 'runtime'
require_relative 'commands/git_actions'
require_relative 'commands/mgit_publish'

module Pod
  class Informative < StandardError; end unless const_defined?(:Informative)

  module UI
    def self.puts(message = '')
      Kernel.puts(message)
    end
  end unless const_defined?(:UI)
end unless defined?(Pod)

module CocoapodsPodx
  class MgitStandalone
    include CocoapodsPodx::Commands::GitActions
    include CocoapodsPodx::Commands::MgitPublish

    def self.run(argv)
      new(argv).run
    rescue Pod::Informative => e
      warn "[!] #{e.message}"
      exit 1
    end

    def initialize(argv)
      @project_directory = find_project_directory(Dir.pwd)
      @pod_names = []
      @dry_run = false
      args = argv.dup
      @product_line = extract_product_line_option!(args)
      CocoapodsPodx::Runtime.configure(project_directory: project_directory, product_line: @product_line)
      parse_arguments(args)
    end

    def run
      if @git_publish_mode
        publish_git_branches
      elsif @commit_mode
        commit_repos(load_entries)
      elsif @branch_mode
        show_branch_info
      elsif git_action_mode?
        git_action_repos(load_entries)
      else
        print_help
      end
    end

    def project_directory
      @project_directory
    end

    def config_path
      preferred = File.join(project_directory, CocoapodsPodx::Runtime::CONFIG_FILE_NAME)
      return preferred if File.exist?(preferred)

      legacy = File.join(project_directory, CocoapodsPodx::Runtime::LEGACY_CONFIG_FILE_NAME)
      return legacy if File.exist?(legacy)

      preferred
    end

    def overlay_path
      CocoapodsPodx::Runtime.send(:overlay_path)
    rescue
      File.join(project_directory, 'Podfile.overlay')
    end

    def podfile_path
      File.join(project_directory, 'Podfile')
    end

    private

    def extract_product_line_option!(argv)
      product_line = nil
      filtered = []
      index = 0

      while index < argv.length
        arg = argv[index].to_s
        if arg == '--line' || arg == '--product-line'
          value = argv[index + 1].to_s.strip
          raise Pod::Informative, "缺少参数值：#{arg}" if value.empty?

          product_line = value
          index += 2
        elsif arg.start_with?('--line=')
          product_line = arg.sub(/\A--line=/, '').strip
          index += 1
        elsif arg.start_with?('--product-line=')
          product_line = arg.sub(/\A--product-line=/, '').strip
          index += 1
        else
          filtered << argv[index]
          index += 1
        end
      end

      argv.replace(filtered)
      product_line
    end

    def parse_arguments(argv)
      if argv.first == 'dry-run'
        @dry_run = true
        argv.shift
      end

      action = argv.shift.to_s
      case action
      when '', 'help', '--help', '-h'
        @help_mode = true
        return
      when 'branch'
        @branch_mode = true
      when 'checkout'
        @checkout_mode = true
      when 'merge'
        @merge_mode = true
      when 'stash'
        @stash_mode = true
        parse_stash_subcommand!(argv)
      when 'status'
        @status_mode = true
      when 'diff'
        @diff_mode = true
      when 'log'
        @log_mode = true
      when 'add'
        @add_mode = true
      when 'pull'
        @pull_mode = true
      when 'rebase'
        @rebase_mode = true
        parse_rebase_subcommand!(argv)
      when 'push'
        @push_mode = true
      when 'commit'
        @commit_mode = true
      when 'publish'
        @git_publish_mode = true
      else
        raise Pod::Informative, "未知 mgit 命令：#{action}"
      end

      parse_options(argv)
      normalize_git_add_arguments!
      extract_checkout_branch_from_arguments!
      extract_merge_branch_from_arguments!
      validate_stash_subcommand_arguments!
      validate_rebase_subcommand_arguments!
    end

    def parse_stash_subcommand!(argv)
      subcommand = argv.first.to_s
      case subcommand
      when 'apply'
        @stash_apply_mode = true
        argv.shift
      when 'list'
        @stash_list_mode = true
        argv.shift
      when 'help', '--help', '-h'
        @help_mode = true
        argv.shift
      when 'pop'
        raise Pod::Informative, 'mgit 不支持 stash pop；请使用更安全的 mgit stash apply NAME'
      end
    end

    def parse_rebase_subcommand!(argv)
      subcommand = argv.first.to_s
      case subcommand
      when '--continue'
        @rebase_continue_mode = true
        argv.shift
      when '--abort'
        @rebase_abort_mode = true
        argv.shift
      when 'help', '--help', '-h'
        @help_mode = true
        argv.shift
      end
    end

    def parse_options(argv)
      pending_option = nil
      argv.each do |arg|
        if pending_option
          assign_option(pending_option, arg)
          pending_option = nil
          next
        end

        case arg
        when '--dry-run'
          @dry_run = true
        when '--rebase'
          @pull_ff_only = false
        when '--ff-only'
          @pull_ff_only = true
        when '-A', '--all', '.'
          @pod_names << arg
        when '-b', '--branch'
          pending_option = arg
          @checkout_create_branch = true if @checkout_mode
        when '-m', '--message', '--limit', '--base-branch', '--push-mode', '--publish-work-dir', '-edit', '--edit'
          pending_option = arg
        when /\A--message=(.+)\z/
          @commit_message = Regexp.last_match(1)
          @stash_message = Regexp.last_match(1)
        when /\A--limit=(.+)\z/
          @log_limit = Regexp.last_match(1)
        when /\A--base-branch=(.+)\z/
          @git_publish_base_branch = Regexp.last_match(1)
        when /\A--push-mode=(.+)\z/
          @git_publish_push_mode = Regexp.last_match(1)
        when /\A--publish-work-dir=(.+)\z/
          @git_publish_work_dir = Regexp.last_match(1)
        when /\A--branch=(.+)\z/
          @checkout_create_branch = true if @checkout_mode
          @checkout_branch = Regexp.last_match(1)
        when /\A(?:-edit|--edit)=(.+)\z/
          (@protected_edit_files ||= []) << Regexp.last_match(1)
        when /\A-/
          raise Pod::Informative, "不支持参数：#{arg}"
        else
          @pod_names << arg
        end
      end

      raise Pod::Informative, "缺少参数值：#{pending_option}" if pending_option
    end

    def assign_option(option, value)
      case option
      when '-m', '--message'
        @commit_message = value
        @stash_message = value
      when '--limit'
        @log_limit = value
      when '--base-branch'
        @git_publish_base_branch = value
      when '--push-mode'
        @git_publish_push_mode = value
      when '--publish-work-dir'
        @git_publish_work_dir = value
      when '-b', '--branch'
        @checkout_create_branch = true if @checkout_mode
        @checkout_branch = value
      when '-edit', '--edit'
        (@protected_edit_files ||= []) << value
      end
    end

    def extract_checkout_branch_from_arguments!
      return unless @checkout_mode

      if @checkout_branch.to_s.strip.empty? && @pod_names.length == 1 && overlay_target_name?(@pod_names.first)
        raise Pod::Informative, "缺少 checkout 目标分支：mgit checkout #{@pod_names.first} BRANCH"
      end

      @checkout_branch = @pod_names.pop.to_s.strip if @checkout_branch.to_s.strip.empty?
      raise Pod::Informative, '请指定 checkout 目标分支，例如：mgit checkout release/5.14.2' if @checkout_branch.empty?
      raise Pod::Informative, "checkout 目标分支不能使用示例占位符：#{@checkout_branch}，请使用真实分支，例如：mgit checkout release/5.14.2" if mgit_placeholder_argument?(@checkout_branch)
    end

    def extract_merge_branch_from_arguments!
      return unless @merge_mode

      if @pod_names.length == 1 && overlay_target_name?(@pod_names.first)
        raise Pod::Informative, "缺少 merge 来源分支：mgit merge #{@pod_names.first} BRANCH"
      end

      @merge_branch = @pod_names.pop.to_s.strip
      raise Pod::Informative, '请指定 merge 来源分支，例如：mgit merge develop' if @merge_branch.empty?
      raise Pod::Informative, "merge 来源分支不能使用示例占位符：#{@merge_branch}，请使用真实分支，例如：mgit merge develop" if mgit_placeholder_argument?(@merge_branch)
    end

    def validate_stash_subcommand_arguments!
      return unless @stash_mode
      return if @stash_list_mode
      return unless @stash_apply_mode
      return if @pod_names.length == 1

      raise Pod::Informative, 'mgit stash apply 必须指定一个仓库，例如：mgit stash apply AppFeatureKit'
    end

    def validate_rebase_subcommand_arguments!
      return unless @rebase_mode
      return if @help_mode
      return if @rebase_continue_mode || @rebase_abort_mode

      raise Pod::Informative, 'mgit rebase 只支持 --continue 或 --abort，例如：mgit rebase --continue'
    end

    def mgit_placeholder_argument?(value)
      text = value.to_s.strip
      return true if text.match?(/\A\[.+\]\z/)
      return true if %w[BRANCH VERSION BUILD NAME N].include?(text)
      return true if text.match?(%r{\Arelease/[xyz](?:\.[xyz])+\z}i)

      false
    end

    def overlay_target_name?(name)
      supported_overlay_names.include?(name.to_s)
    end

    def git_action_mode?
      @checkout_mode || @merge_mode || @stash_mode || @status_mode || @diff_mode || @log_mode || @add_mode || @pull_mode || @rebase_mode || @push_mode
    end

    def load_entries
      return [] unless File.exist?(overlay_path)

      overlay = CocoapodsPodx::Runtime::PodOverlay.new
      overlay.instance_eval(File.read(overlay_path), overlay_path)
      overlay.raw_pods.keys.map { |name| { name: name } }
    end

    def supported_overlay_names
      names = CocoapodsPodx::Runtime.podfile_supported_overlay_names
      return names unless names.empty?

      load_entries.map { |entry| entry[:name] }
    end

    def declared_managed_pod_branches
      @declared_managed_pod_branches ||= begin
        branches = {}
        CocoapodsPodx::Runtime.managed_pod_entries.each do |entry|
          next if entry[:group_name] && entry[:group_name] != 'app_ios'

          branches[entry[:name]] = entry[:branch] if entry[:branch]
        end
        branches
      end
    end

    def declared_biz_group_branches
      @declared_biz_group_branches ||= begin
        branches = {}
        CocoapodsPodx::Runtime.managed_pod_entries.each do |entry|
          group_name = entry[:group_name]
          next if group_name.nil? || group_name == 'app_ios'

          branches[group_name] ||= entry[:branch] if entry[:branch]
        end
        branches
      end
    end

    def declared_branch_for(name)
      declared_managed_pod_branches[name] || declared_biz_group_branches[name]
    end

    def local_repo_path_for(name)
      fast_path = fast_local_repo_path_for(name)
      return fast_path if fast_path

      repo_dir = CocoapodsPodx::Runtime.local_repo_folder_name_for(name)
      File.expand_path(File.join(project_directory, 'Development Pods', repo_dir))
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
      Pod::UI.puts [name, '[updated]', checkout_message].join(' ') unless quiet
      true
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

    def fast_local_repo_path_for(name)
      root = File.join(project_directory, 'Development Pods')
      return nil unless File.directory?(root)

      raw_name = name.to_s.include?('/') ? name.to_s.split('/').first : name.to_s
      candidates = [
        raw_name,
        raw_name.downcase,
        raw_name.gsub(/([a-z\d])([A-Z])/, '\\1_\\2').downcase
      ].uniq
      candidates.each do |candidate|
        path = File.expand_path(File.join(root, candidate))
        return path if File.directory?(path)
      end

      nil
    end

    def main_app_branch
      git_branch_for(project_directory) || git_branch_for(Dir.pwd)
    end

    def show_branch_info
      names = @pod_names.empty? ? load_entries.map { |entry| entry[:name] } : @pod_names
      app_branch = main_app_branch
      rows = [['main', app_branch || 'unknown', app_branch ? '当前' : '未知', '-']]
      names.each do |name|
        status = branch_status_for(name, app_branch)
        rows << [
          name,
          status[:branch] || '-',
          branch_status_label(status[:tag]),
          status[:app_branch] || '-'
        ]
      end

      git_action_print_table('branch 结果', %w[仓库 当前分支 状态 对齐分支], rows)
      Pod::UI.puts "【branch 汇总】主工程 #{app_branch || 'unknown'}，组件 #{names.length} 个"
    end

    def branch_status_for(name, app_branch)
      repo_path = local_repo_path_for(name)
      return { tag: 'missing', branch: nil } unless File.directory?(repo_path)

      branch = git_branch_for(repo_path)
      return { tag: 'unknown', branch: nil } if branch.nil?
      return { tag: 'unknown', branch: branch } if app_branch.nil?

      branch == app_branch ? { tag: 'ok', branch: branch } : { tag: 'no', branch: branch, app_branch: app_branch }
    end

    def branch_status_label(tag)
      case tag
      when 'ok'
        '已对齐'
      when 'no'
        '未对齐'
      when 'missing'
        '缺失'
      else
        '未知'
      end
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

    def git_remote_has_updates?(path, branch)
      local, local_status = Open3.capture2('git', '-C', path, 'rev-parse', branch)
      remote, remote_status = Open3.capture2('git', '-C', path, 'rev-parse', "origin/#{branch}")
      return true unless local_status.success? && remote_status.success?

      local.strip != remote.strip
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
      if @checkout_create_branch && !git_local_branch_exists?(path, branch) && !git_remote_branch_exists?(path, branch)
        run_git!(path, 'checkout', '-b', branch)
        return
      end

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

    def git_remote_url
      stdout, status = Open3.capture2e('git', '-C', project_directory, 'remote', 'get-url', 'origin')
      return nil unless status.success?

      stdout.strip
    end

    def inferred_project_config
      git_base_url, target_name = infer_git_base_and_target
      {
        target_name: target_name || File.basename(project_directory),
        git_base_url: git_base_url,
      }
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

    def find_project_directory(start_dir)
      current_dir = File.expand_path(start_dir)
      original_dir = current_dir

      loop do
        return current_dir if File.exist?(File.join(current_dir, 'podx.config.yml')) ||
          File.exist?(File.join(current_dir, 'Podfile.overlay.config.yml')) ||
          File.exist?(File.join(current_dir, 'Podfile')) ||
          File.exist?(File.join(current_dir, '.git'))

        parent_dir = File.dirname(current_dir)
        break if parent_dir == current_dir

        current_dir = parent_dir
      end

      File.expand_path(original_dir)
    end

    def print_help
      Pod::UI.puts <<~HELP
        mgit 是多仓库 git 命令入口，无需 CocoaPods：
          mgit branch [NAME]
          mgit checkout [NAME] BRANCH
          mgit checkout -b BRANCH
          mgit checkout --branch BRANCH
          mgit merge [NAME] BRANCH
          mgit stash [NAME]
          mgit stash list [NAME]
          mgit stash apply NAME
          mgit status [NAME]
          mgit diff [NAME]
          mgit log [NAME] [--limit N]
          mgit add [NAME]
          mgit add .
          mgit add -A
          mgit pull [NAME]
          mgit pull --ff-only [NAME]
          mgit rebase --continue
          mgit rebase --abort
          mgit push [NAME]
          mgit commit [NAME] -m "msg"
          mgit commit -m "msg" -edit Podfile
          mgit publish BRANCH
          mgit dry-run <command>
      HELP
    end
  end
end
