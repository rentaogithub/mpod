
require 'pathname'
require_relative '../rules'

module CocoapodsPodx
  module Commands
    module GitActions
      def git_action_repos(entries)
        action = git_action_name
        repos = commit_targets(entries)
        if repos.empty?
          Pod::UI.puts "#{action} [skip] 没有可处理的本地仓库。"
          return
        end

        failures = []
        done_count = 0
        skipped_count = 0
        rows = []
        detail_sections = []

        repos.each do |repo|
          name = repo[:name]
          path = repo[:path]

          if action == 'pull' && repo[:source].to_s == '远端'
            rows << [name, repo[:branch] || '-', '-', repo[:commit] || '-', path, '远端']
            skipped_count += 1
            next
          end

          unless File.directory?(path)
            rows << [name, '-', 'missing', '-', path]
            skipped_count += 1
            next
          end

          snapshot = git_action_repo_snapshot(path)
          unless snapshot[:work_tree]
            rows << [name, '-', 'not-git', '-', path]
            skipped_count += 1
            next
          end

          branch = snapshot[:branch]
          status = snapshot[:status_lines]

          begin
            case action
            when 'status'
              commit = git_short_head(path)
              update = snapshot[:update]
              if status.empty?
                rows << [name, branch || 'detached', 'clean', '-', path, commit, update]
                skipped_count += 1
              else
                rows << [name, branch || 'detached', 'changed', git_changed_file_summary(status), path, commit, update]
                done_count += 1
              end
            when 'diff'
              diff = git_diff_lines(path)
              if diff.empty?
                rows << [name, branch || 'detached', 'clean', '-', path]
                skipped_count += 1
              else
                rows << [name, branch || 'detached', 'diff', "#{diff.length} lines", path]
                detail_sections << [name, diff]
                done_count += 1
              end
            when 'log'
              log_lines = git_log_lines(path, log_limit)
              if log_lines.empty?
                rows << [name, branch || 'detached', 'empty', '-', path]
                skipped_count += 1
              else
                rows << [name, branch || 'detached', 'log', git_action_summary(log_lines), path]
                detail_sections << [name, log_lines]
                done_count += 1
              end
            when 'checkout'
              if @checkout_branch.to_s.strip.empty?
                rows << [name, branch || 'detached', 'skip', 'branch empty', path]
                skipped_count += 1
              elsif branch == @checkout_branch
                rows << [name, branch, 'skip', "already #{@checkout_branch}", path]
                skipped_count += 1
              elsif git_dirty?(path)
                rows << [name, branch || 'detached', 'skip', 'dirty', path]
                skipped_count += 1
              elsif @dry_run
                rows << [name, @checkout_branch, 'dry-run', "checkout -> #{@checkout_branch}", path]
                done_count += 1
              else
                run_git!(path, 'fetch', 'origin')
                checkout_branch!(path, @checkout_branch)
                rows << [name, @checkout_branch, 'checkout', "-> #{@checkout_branch}", path]
                done_count += 1
              end
            when 'merge'
              branch, align_state = align_git_action_branch(name, path, branch, status)
              status = git_status_lines(path) if align_state == :checkout
              if @merge_branch.to_s.strip.empty?
                rows << [name, branch || 'detached', 'skip', 'branch empty', path]
                skipped_count += 1
              elsif align_state == :dirty_branch
                rows << [name, branch || 'detached', 'skip', 'dirty', path]
                skipped_count += 1
              elsif branch.nil?
                rows << [name, 'detached', 'skip', 'detached', path]
                skipped_count += 1
              elsif git_dirty?(path)
                rows << [name, branch, 'skip', 'dirty', path]
                skipped_count += 1
              elsif @dry_run
                detail = align_state == :dry_run_checkout ? "checkout -> #{branch}; merge origin/#{@merge_branch}" : "merge origin/#{@merge_branch}"
                rows << [name, branch, 'dry-run', detail, path]
                done_count += 1
              else
                before_commit = git_full_head(path)
                run_git!(path, 'fetch', 'origin', @merge_branch)
                after_commit, restored_files = run_git_action_merge!(name, path, before_commit, "origin/#{@merge_branch}")
                if before_commit != after_commit
                  detail = git_commit_summary(path, after_commit)
                  detail = "#{detail}; 已还原 #{restored_files.join(', ')}" if restored_files.any?
                  rows << [name, branch, 'merged', detail, path]
                  done_count += 1
                else
                  rows << [name, branch, 'up-to-date', '-', path]
                  skipped_count += 1
                end
              end
            when 'stash'
              if @stash_list_mode
                stash_lines = git_stash_lines(path)
                if stash_lines.empty?
                  rows << [name, branch || 'detached', 'empty', '-', path]
                  skipped_count += 1
                else
                  rows << [name, branch || 'detached', 'stash-list', git_action_summary(stash_lines), path]
                  detail_sections << [name, stash_lines]
                  done_count += 1
                end
              elsif @stash_apply_mode
                stash_ref = @stash_ref.to_s.strip
                stash_ref = 'stash@{0}' if stash_ref.empty?
                if git_stash_lines(path).empty?
                  rows << [name, branch || 'detached', 'skip', 'stash empty', path]
                  skipped_count += 1
                elsif @dry_run
                  rows << [name, branch || 'detached', 'dry-run', "apply #{stash_ref}", path]
                  done_count += 1
                else
                  run_git!(path, 'stash', 'apply', stash_ref)
                  rows << [name, branch || 'detached', 'stash-applied', stash_ref, path]
                  done_count += 1
                end
              elsif status.empty?
                rows << [name, branch || 'detached', 'skip', 'clean', path]
                skipped_count += 1
              elsif @dry_run
                rows << [name, branch || 'detached', 'dry-run', git_changed_file_summary(status), path]
                done_count += 1
              else
                message = @stash_message.to_s.strip
                message = "mgit stash #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}" if message.empty?
                run_git!(path, 'stash', 'push', '-u', '-m', message)
                rows << [name, branch || 'detached', 'stashed', git_changed_file_summary(status), path]
                done_count += 1
              end
            when 'add'
              if status.empty?
                rows << [name, branch || 'detached', 'skip', 'clean', path]
                skipped_count += 1
              elsif @dry_run
                rows << [name, branch || 'detached', 'dry-run', git_action_summary(status), path]
                done_count += 1
              else
                run_git!(path, 'add', '-A')
                rows << [name, branch || 'detached', 'added', git_action_summary(status), path]
                done_count += 1
              end
            when 'pull'
              branch, align_state = align_git_action_branch(name, path, branch, status)
              status = git_status_lines(path) if align_state == :checkout
              if align_state == :dirty_branch
                rows << [name, branch || 'detached', '跳过', 'dirty', path]
                skipped_count += 1
              elsif branch.nil?
                rows << [name, 'detached', '跳过', 'detached', path]
                skipped_count += 1
              elsif @dry_run
                pull_detail = git_pull_command_args(branch).join(' ')
                detail = align_state == :dry_run_checkout ? "checkout -> #{branch}; #{pull_detail}" : pull_detail
                rows << [name, branch, '预览', detail, path]
                done_count += 1
              else
                before_commit = git_short_head(path)
                run_git!(path, *git_pull_command_args(branch))
                after_commit = git_short_head(path)
                if before_commit != after_commit
                  rows << [name, branch, '有更新', git_commit_summary(path, after_commit), path, '本地']
                  done_count += 1
                else
                  rows << [name, branch, '-', after_commit, path, '本地']
                  skipped_count += 1
                end
              end
            when 'rebase'
              if !git_rebase_in_progress?(path)
                rows << [name, branch || 'detached', 'skip', 'no rebase', path]
                skipped_count += 1
              elsif @dry_run
                rows << [name, branch || 'detached', 'dry-run', git_rebase_command_args.join(' '), path]
                done_count += 1
              else
                run_git!(path, *git_rebase_command_args)
                rows << [name, branch || 'detached', @rebase_abort_mode ? 'rebase-aborted' : 'rebase-continued', git_rebase_command_args.join(' '), path]
                done_count += 1
              end
            when 'push'
              branch, align_state = align_git_action_branch(name, path, branch, status)
              if align_state == :dirty_branch
                rows << [name, branch || 'detached', 'skip', 'dirty', path]
                skipped_count += 1
              elsif branch.nil?
                rows << [name, 'detached', 'skip', 'detached', path]
                skipped_count += 1
              elsif @dry_run
                detail = align_state == :dry_run_checkout ? "checkout -> #{branch}; push origin/#{branch}" : "push origin/#{branch}"
                rows << [name, branch, 'dry-run', detail, path]
                done_count += 1
              else
                local_commit = git_full_head(path)
                ahead_count = snapshot[:ahead_count]
                ahead_count = git_ahead_count(path, branch) if ahead_count.nil?
                if ahead_count == 0
                  rows << [name, branch, 'up-to-date', '-', path]
                  skipped_count += 1
                else
                  run_git!(path, 'push', 'origin', branch)
                  rows << [name, branch, 'pushed', git_commit_summary(path, local_commit), path]
                  done_count += 1
                end
              end
            end
          rescue => e
            rows << [name, branch || 'detached', 'failed', e.message, path]
            failures << "#{name}: #{e.message}"
          end
        end

        if action == 'pull'
          git_action_print_table("#{action} #{'dry-run ' if @dry_run}结果", %w[仓库 来源 分支 更新 Commit], rows.map { |row| git_pull_table_row(row) })
          if rows.any? { |row| row[2].to_s == '跳过' && row[3].to_s == 'dirty' }
            Pod::UI.puts '【pull 提示】存在分支不一致且有本地变更的仓库已跳过；请先提交或 mgit stash 后再执行 mgit pull。'
          end
        elsif action == 'status'
          git_action_print_table("#{action} 结果", %w[仓库 分支 Commit 更新 本地变更], rows.map { |row| git_status_table_row(row) })
        elsif action == 'stash'
          git_action_print_table("#{action} #{'dry-run ' if @dry_run}结果", %w[仓库 分支 变更], rows.map { |row| git_stash_table_row(row) })
        elsif %w[add checkout merge rebase push].include?(action)
          git_action_print_table("#{action} #{'dry-run ' if @dry_run}结果", %w[仓库 分支 状态], rows.map { |row| git_simple_action_table_row(row) })
        else
          git_action_print_table("#{action} #{'dry-run ' if @dry_run}结果", %w[仓库 分支 状态 详情 路径], rows)
        end
        git_action_print_detail_sections(action, detail_sections) if detail_sections.any?

        if failures.any?
          raise Pod::Informative, "以下仓库 #{action} 失败：\n#{failures.join("\n")}"
        end

        label = @dry_run ? "#{action} 预览" : "#{action} 汇总"
        Pod::UI.puts "【#{label}】处理 #{done_count} 个，跳过 #{skipped_count} 个"
      end

      def git_action_name
        return 'status' if @status_mode
        return 'diff' if @diff_mode
        return 'log' if @log_mode
        return 'checkout' if @checkout_mode
        return 'merge' if @merge_mode
        return 'stash' if @stash_mode
        return 'add' if @add_mode
        return 'pull' if @pull_mode
        return 'rebase' if @rebase_mode
        return 'push' if @push_mode

        'unknown'
      end

      def normalize_git_add_arguments!
        return unless @add_mode

        @pod_names = @pod_names.reject { |name| ['.', '-A', '--all'].include?(name.to_s) }
      end

      def log_limit
        limit = @log_limit.to_s.strip
        return '5' if limit.empty?
        return limit if limit.match?(/\A[1-9]\d*\z/)

        '5'
      end

      def commit_repos(entries)
        if !@dry_run && (@commit_message.nil? || @commit_message.strip.empty?)
          raise Pod::Informative, '请通过 -m "提交说明" 指定组合提交信息。'
        end

        repos = commit_targets(entries)
        if repos.empty?
          Pod::UI.puts 'commit [skip] 没有可提交的本地仓库。'
          return
        end

        failures = []
        committed_count = 0
        skipped_count = 0
        rows = []

        repos.each do |repo|
          name = repo[:name]
          path = repo[:path]

          unless File.directory?(path)
            rows << [name, '-', 'missing']
            skipped_count += 1
            next
          end

          unless git_work_tree?(path)
            rows << [name, '-', 'not-git']
            skipped_count += 1
            next
          end

          branch = git_branch_for(path) || 'detached'
          status = git_status_lines(path)
          branch, align_state = align_git_action_branch(name, path, branch == 'detached' ? nil : branch, status)
          branch ||= 'detached'
          status = git_status_lines(path) if align_state == :checkout
          if align_state == :dirty_branch
            rows << [name, branch, 'skip', 'dirty']
            skipped_count += 1
            next
          end

          if status.empty?
            rows << [name, branch, 'skip', 'clean']
            skipped_count += 1
            next
          end

          if @dry_run
            rows << [name, branch, 'dry-run']
            committed_count += 1
            next
          end

          begin
            run_git!(path, 'add', '-A')
            if git_action_protected_edit_commit?(name, status)
              with_git_action_protected_commit_allowed do
                run_git!(path, 'commit', '-m', @commit_message.strip)
              end
            else
              run_git!(path, 'commit', '-m', @commit_message.strip)
            end
            rows << [name, branch, 'committed']
            committed_count += 1
          rescue => e
            rows << [name, branch, 'failed']
            failures << "#{name}: #{e.message}"
          end
        end

        title = @dry_run ? 'commit dry-run 结果' : 'commit 结果'
        git_action_print_table(title, %w[仓库 分支 状态], rows.map { |row| git_simple_action_table_row(row) })

        if failures.any?
          raise Pod::Informative, "以下仓库提交失败：\n#{failures.join("\n")}"
        end

        label = @dry_run ? 'commit 预览' : 'commit 汇总'
        Pod::UI.puts "【#{label}】处理 #{committed_count} 个，跳过 #{skipped_count} 个"
      end

      def git_action_protected_edit_commit?(name, status)
        return false unless name.to_s == 'main'

        files = Array(@protected_edit_files).map { |file| File.basename(file.to_s.strip) }.reject(&:empty?)
        return false if files.empty?

        changed_files = Array(status).map { |line| File.basename(line.to_s.split(/\s+/).last.to_s) }
        !(files & changed_files).empty?
      end

      def with_git_action_protected_commit_allowed
        rule = CocoapodsPodx::Rules::CommitProtection.new(config: {})
        previous = ENV[rule.allow_env]
        ENV[rule.allow_env] = rule.allow_context
        yield
      ensure
        if previous.nil?
          ENV.delete(rule.allow_env)
        else
          ENV[rule.allow_env] = previous
        end
      end

      def run_git_action_merge!(name, path, before_commit, source_ref)
        protected_files = git_action_protected_files_for_merge(name)
        merge_args = ['merge', '--no-edit', '--no-stat']
        merge_args << '--no-ff' if protected_files.any?
        merge_args << source_ref
        run_git!(path, *merge_args)

        after_commit = git_full_head(path)
        restored_files = restore_git_action_protected_files_after_merge(path, before_commit, after_commit, protected_files)
        after_commit = git_full_head(path) if restored_files.any?
        [after_commit, restored_files]
      end

      def git_action_protected_files_for_merge(name)
        return [] unless name.to_s == 'main'

        config_path_value = respond_to?(:config_path, true) ? config_path : nil
        CocoapodsPodx::Rules.engine(config_path: config_path_value).commit_protection.protected_files
      rescue
        CocoapodsPodx::Rules::CommitProtection.new(config: {}).protected_files
      end

      def restore_git_action_protected_files_after_merge(path, before_commit, after_commit, protected_files)
        return [] if Array(protected_files).empty?
        return [] if before_commit.to_s.empty? || after_commit.to_s.empty? || before_commit == after_commit

        restored_files = []
        Array(protected_files).each do |file|
          file = file.to_s.strip
          next if file.empty?
          next unless git_path_changed_between?(path, before_commit, after_commit, file)

          if git_path_exists_at?(path, before_commit, file)
            run_git!(path, 'checkout', before_commit, '--', file)
          else
            run_git!(path, 'rm', '-f', '--quiet', '--', file)
          end
          restored_files << file
        end
        return [] if restored_files.empty?

        run_git!(path, 'commit', '--amend', '--no-edit')
        restored_files
      end

      def git_path_changed_between?(path, before_commit, after_commit, file)
        _stdout, status = Open3.capture2('git', '-C', path, 'diff', '--quiet', before_commit, after_commit, '--', file)
        !status.success?
      end

      def git_path_exists_at?(path, commit, file)
        _stdout, status = Open3.capture2('git', '-C', path, 'cat-file', '-e', "#{commit}:#{file}")
        status.success?
      end

      def align_git_action_branch(name, path, branch, status)
        target_branch = main_git_action_branch
        return [branch, nil] if target_branch.to_s.empty?
        return [branch, nil] if name.to_s == 'main'
        return [branch, nil] if File.expand_path(path) == File.expand_path(project_directory)
        return [branch, nil] if branch == target_branch

        return [branch, :dirty_branch] unless Array(status).empty?

        if @dry_run
          return [target_branch, :dry_run_checkout]
        end

        run_git!(path, 'fetch', 'origin')
        checkout_branch!(path, target_branch)
        [target_branch, :checkout]
      end

      def main_git_action_branch
        @main_git_action_branch ||= git_branch_for(project_directory)
      end

      def commit_targets(entries)
        return merge_commit_targets(entries) if @merge_mode && @pod_names.empty? && !@merge_branch.to_s.strip.empty?
        return pull_commit_targets(entries) if @pull_mode

        if @pod_names.empty?
          [{ name: 'main', path: project_directory }] + entries.map do |entry|
            { name: entry[:name], path: local_repo_path_for(entry[:name]) }
          end
        else
          @pod_names.map do |name|
            name == 'main' ? { name: 'main', path: project_directory } : { name: name, path: local_repo_path_for(name) }
          end
        end
      end

      def pull_commit_targets(entries)
        names = if @pod_names.empty?
          if respond_to?(:supported_overlay_names, true)
            Array(supported_overlay_names)
          else
            entries.map { |entry| entry[:name] }
          end
        else
          @pod_names
        end
        local_names = entries.map { |entry| entry[:name].to_s }.uniq
        targets = [{ name: 'main', path: project_directory, source: '本地' }]
        names.map(&:to_s).reject(&:empty?).uniq.each do |name|
          if local_names.include?(name)
            targets << { name: name, path: local_repo_path_for(name), source: '本地' }
          else
            branch = pull_remote_branch_for(name)
            targets << { name: name, path: nil, source: '远端', branch: branch, commit: '-' }
          end
        end
        targets
      end

      def pull_remote_branch_for(name)
        branch = declared_branch_for(name) if respond_to?(:declared_branch_for, true)
        branch = main_git_action_branch if branch.to_s.empty?
        branch.to_s.empty? ? '-' : branch
      end

      def pull_remote_commit_for(name, branch)
        return '-' if branch.to_s.empty? || branch.to_s == '-'

        url = CocoapodsPodx::Runtime.remote_repo_url_for(name)
        CocoapodsPodx::Runtime.send(:remote_branch_commit_hash, url, branch)
      rescue
        '-'
      end

      def merge_commit_targets(entries)
        prepare_full_merge_source_branch(merge_component_names(entries))
        sync_overlay_to_all_merge_components(entries)
        targets = [{ name: 'main', path: project_directory }]
        seen = { 'main' => true }
        merge_component_names(entries).each do |name|
          next if seen[name]

          targets << { name: name, path: local_repo_path_for(name) }
          seen[name] = true
        end

        targets
      end

      def prepare_full_merge_source_branch(names)
        return if @dry_run

        source_branch = @merge_branch.to_s.strip
        target_branch = main_git_action_branch.to_s.strip
        return if source_branch.empty? || target_branch.empty? || source_branch == target_branch

        failures = []
        prepared_count = 0
        Array(names).each do |name|
          path = local_repo_path_for(name)
          next unless File.directory?(path)

          unless git_work_tree?(path)
            failures << "#{name}: 不是 git 仓库：#{path}"
            next
          end

          current_branch = git_branch_for(path)
          status = git_status_lines(path)
          unless Array(status).empty?
            failures << "#{name}: 本地仓库存在未提交修改：#{path}"
            next
          end

          begin
            run_git!(path, 'fetch', 'origin')
            checkout_branch!(path, source_branch) unless current_branch == source_branch
            run_git!(path, 'pull', '--ff-only', 'origin', source_branch)
            checkout_branch!(path, target_branch) unless source_branch == target_branch
            prepared_count += 1
          rescue => e
            failures << "#{name}: #{e.message}"
            begin
              checkout_branch!(path, current_branch) if current_branch && git_branch_for(path) != current_branch
            rescue
              nil
            end
          end
        end

        if failures.any?
          raise Pod::Informative, "merge 前准备来源分支失败：\n#{failures.join("\n")}"
        end

        Pod::UI.puts "merge [prepare] #{source_branch} 本地组件 #{prepared_count} 个" if prepared_count.positive?
      end

      def merge_component_names(entries)
        overlay_names = entries.map { |entry| entry[:name].to_s }.reject(&:empty?).uniq
        candidate_names = if respond_to?(:supported_overlay_names, true)
          Array(supported_overlay_names).map(&:to_s)
        else
          overlay_names
        end
        (overlay_names + candidate_names).reject(&:empty?).uniq
      end

      def sync_overlay_to_all_merge_components(entries)
        return if @dry_run
        return unless respond_to?(:overlay_path, true)

        names = merge_component_names(entries)
        return if names.empty?

        current_names = entries.map { |entry| entry[:name].to_s }.reject(&:empty?).uniq
        missing_names = names - current_names
        return if missing_names.empty?

        write_overlay_names(names)
        Pod::UI.puts "Podfile.overlay [updated] merge 本地组件 #{names.length} 个"
      end

      def write_overlay_names(names)
        lines = if File.exist?(overlay_path)
          File.readlines(overlay_path, chomp: true)
        else
          default_merge_overlay_lines
        end

        header_lines = lines.take_while { |line| !line.match?(/^\s*pod\s+['"][^'"]+['"]/) }
        header_lines = trim_git_action_blank_lines(header_lines)
        content_lines = header_lines + [''] + names.map { |name| "pod '#{name}'" }
        content_lines = trim_git_action_blank_lines(content_lines)
        content_lines << ''
        File.write(overlay_path, content_lines.join("\n"))
      end

      def default_merge_overlay_lines
        [
          '# 本地源码覆盖配置',
          '# 这里只声明哪些组件切到本地源码。',
          '# 未出现在 Podfile.overlay 中的组件默认走远端。',
          '# 不要写 localWork、branch 或其他参数。',
          '# 示例：',
          "# pod 'NNBussCom'                    # 业务组件组切本地",
          "# pod 'NNBasciCommon'               # 单个组件切本地",
          "# pod 'NNIMManager'                 # 单个组件切本地",
          "# pod 'NNApperance'                 # 单个组件切本地",
          ''
        ]
      end

      def trim_git_action_blank_lines(lines)
        result = Array(lines).dup
        result.pop while result.any? && result.last.to_s.strip.empty?
        result
      end

      def merge_branch_component_changed?(name)
        repo_path = local_repo_path_for(name)
        return false unless File.directory?(repo_path)
        return false unless git_work_tree?(repo_path)

        source_branch = @merge_branch.to_s.strip
        target_branch = main_git_action_branch.to_s.strip
        return false if source_branch.empty?

        fetch_branch_quietly(repo_path, source_branch)
        fetch_branch_quietly(repo_path, target_branch) unless target_branch.empty? || target_branch == source_branch

        source_ref = "origin/#{source_branch}"
        return false unless git_ref_exists?(repo_path, source_ref)

        target_ref = if !target_branch.empty? && git_ref_exists?(repo_path, "origin/#{target_branch}")
          "origin/#{target_branch}"
        else
          'HEAD'
        end

        stdout, status = Open3.capture2('git', '-C', repo_path, 'rev-list', '--count', "#{target_ref}..#{source_ref}")
        status.success? && stdout.to_i.positive?
      rescue
        false
      end

      def fetch_branch_quietly(path, branch)
        return if branch.to_s.strip.empty?

        Open3.capture2e('git', '-C', path, 'fetch', 'origin', branch.to_s)
      end

      def git_ref_exists?(path, ref)
        _stdout, status = Open3.capture2e('git', '-C', path, 'rev-parse', '--verify', '--quiet', ref)
        status.success?
      end

      def git_pull_command_args(branch)
        @pull_ff_only ? ['pull', '--ff-only', 'origin', branch] : ['pull', '--rebase', '--autostash', 'origin', branch]
      end

      def git_rebase_command_args
        @rebase_abort_mode ? ['rebase', '--abort'] : ['rebase', '--continue']
      end

      def git_rebase_in_progress?(path)
        git_dir = git_dir_for(path)
        return false if git_dir.to_s.empty?

        File.directory?(File.join(git_dir, 'rebase-merge')) || File.directory?(File.join(git_dir, 'rebase-apply'))
      end

      def git_dir_for(path)
        stdout, status = Open3.capture2e('git', '-C', path, 'rev-parse', '--git-dir')
        return '' unless status.success?

        git_dir = stdout.strip
        Pathname.new(git_dir).absolute? ? git_dir : File.expand_path(git_dir, path)
      rescue StandardError
        ''
      end

      def git_action_update_status(path, branch)
        return '-' if branch.to_s.empty? || branch.to_s == 'detached'

        return '-' unless git_ref_exists?(path, "refs/remotes/origin/#{branch}")

        stdout, status = Open3.capture2('git', '-C', path, 'rev-list', '--count', "HEAD..refs/remotes/origin/#{branch}")
        return '-' unless status.success?

        stdout.to_i.positive? ? '有更新' : '-'
      rescue
        '-'
      end

      def git_action_repo_snapshot(path)
        stdout, status = Open3.capture2('git', '-C', path, 'status', '--short', '--branch', err: File::NULL)
        unless status.success?
          if git_work_tree?(path)
            branch = git_branch_for(path)
            status_lines = git_status_lines(path)
            return {
              work_tree: true,
              branch: branch,
              status_lines: status_lines,
              update: git_action_update_status(path, branch),
              ahead_count: nil
            }
          end

          return {
            work_tree: false,
            branch: nil,
            status_lines: [],
            update: '-',
            ahead_count: nil
          }
        end

        lines = stdout.lines.map(&:chomp).reject(&:empty?)
        branch_line = lines.first.to_s.start_with?('## ') ? lines.shift : ''
        parsed = git_action_parse_branch_status(branch_line)
        {
          work_tree: true,
          branch: parsed[:branch],
          status_lines: lines,
          update: parsed[:behind_count].positive? ? '有更新' : '-',
          ahead_count: parsed[:ahead_count]
        }
      end

      def git_action_parse_branch_status(line)
        text = line.to_s.sub(/\A##\s*/, '').strip
        return { branch: nil, ahead_count: nil, behind_count: 0 } if text.empty? || text.start_with?('HEAD ')

        branch = text[/No commits yet on\s+(.+)\z/, 1]
        branch ||= text.split('...').first.to_s.split(/\s+/).first
        ahead = text[/ahead\s+(\d+)/, 1]
        behind = text[/behind\s+(\d+)/, 1]
        {
          branch: branch.empty? ? nil : branch,
          ahead_count: ahead.nil? ? nil : ahead.to_i,
          behind_count: behind.nil? ? 0 : behind.to_i
        }
      end

      def git_action_summary(lines, max_width = 48)
        text = Array(lines).join('; ').gsub(/\s+/, ' ').strip
        return '-' if text.empty?
        return text if git_action_display_width(text) <= max_width

        result = +''
        width = 0
        suffix = '...'
        text.each_char do |char|
          char_width = git_action_display_char_width(char)
          break if width + char_width > max_width - git_action_display_width(suffix)

          result << char
          width += char_width
        end
        "#{result}#{suffix}"
      end

      def git_changed_file_summary(status_lines, max_width = 50)
        files = Array(status_lines).map { |line| git_status_file_name(line) }.reject(&:empty?).uniq
        git_action_summary(files, max_width)
      end

      def git_status_file_name(line)
        text = line.to_s.strip
        return '' if text.empty?

        path = text.length > 3 ? text[3..] : text
        path = path.split(' -> ').last if path.include?(' -> ')
        File.basename(path.to_s.strip)
      end

      def git_status_table_row(row)
        repo, branch, status, detail, _path, commit, update = row
        change = status == 'clean' ? '-' : detail
        [repo, branch, commit.to_s.empty? ? '-' : commit, update.to_s.empty? ? '-' : update, change]
      end

      def git_stash_table_row(row)
        repo, branch, status, detail = row
        change = case status.to_s
                 when 'skip', 'clean'
                   '-'
                 when 'dry-run', 'stashed', 'stash-list', 'stash-applied'
                   detail
                 else
                   git_action_status_label(status)
                 end
        [repo, branch, change]
      end

      def git_pull_table_row(row)
        repo, branch, status, detail, _path, source = row
        [repo, source.to_s.empty? ? '本地' : source, branch, status, detail]
      end

      def git_simple_action_table_row(row)
        repo, branch, status, detail = row
        return [repo, branch, '-'] if status.to_s == 'skip' && detail.to_s == 'clean'

        [repo, branch, git_action_status_label(status)]
      end

      def git_action_status_label(status)
        case status.to_s
        when 'skip'
          '跳过'
        when 'dry-run'
          '预览'
        when 'added'
          '已暂存'
        when 'committed'
          '已提交'
        when 'pushed'
          '已推送'
        when 'rebase-continued'
          '已继续'
        when 'rebase-aborted'
          '已放弃'
        when 'up-to-date'
          '-'
        when 'checkout'
          '已切换'
        when 'merged'
          '已合并'
        when 'stashed'
          '已储藏'
        when 'stash-applied'
          '已恢复'
        when 'stash-list'
          '列表'
        when 'missing'
          '缺失'
        when 'not-git'
          '非Git'
        when 'failed'
          '失败'
        else
          status.to_s.empty? ? '-' : status.to_s
        end
      end

      def git_action_print_table(title, headers, rows)
        rows = rows.map { |row| row.map { |value| git_action_cell(value) } }
        headers = headers.map { |value| git_action_cell(value) }
        widths = headers.each_index.map do |index|
          ([git_action_display_width(headers[index])] + rows.map { |row| git_action_display_width(row[index]) }).max
        end

        Pod::UI.puts "【#{title.to_s.strip}】"
        separator = "+#{widths.map { |width| '-' * (width + 2) }.join('+')}+"
        Pod::UI.puts separator
        Pod::UI.puts "| #{headers.each_with_index.map { |value, index| git_action_pad_display(value, widths[index]) }.join(' | ')} |"
        Pod::UI.puts separator
        rows.each do |row|
          Pod::UI.puts "| #{row.each_with_index.map { |value, index| git_action_color_cell(git_action_pad_display(value, widths[index]), value) }.join(' | ')} |"
        end
        Pod::UI.puts separator
      end

      def git_action_print_detail_sections(action, sections)
        sections.each do |name, lines|
          Pod::UI.puts "【#{action} 详情】#{name}"
          lines.each { |line| Pod::UI.puts line }
        end
      end

      def git_action_cell(value)
        text = value.to_s.gsub(/\s+/, ' ').strip
        text.empty? ? '-' : text
      end

      def git_action_display_width(value)
        git_action_strip_ansi(value).each_char.sum { |char| git_action_display_char_width(char) }
      end

      def git_action_display_char_width(char)
        code = char.ord
        return 0 if code.zero?
        return 0 if (0x0300..0x036F).cover?(code)
        return 0 if (0x1AB0..0x1AFF).cover?(code)
        return 0 if (0x1DC0..0x1DFF).cover?(code)
        return 0 if (0x20D0..0x20FF).cover?(code)
        return 0 if (0xFE00..0xFE0F).cover?(code)
        return 0 if (0xFE20..0xFE2F).cover?(code)
        return 2 if git_action_wide_display_char?(code)

        1
      end

      def git_action_wide_display_char?(code)
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

      def git_action_pad_display(value, width)
        text = value.to_s
        text + (' ' * [width - git_action_display_width(text), 0].max)
      end

      def git_action_color_cell(rendered, raw)
        return rendered unless git_action_color_enabled?

        case raw.to_s.strip
        when '本地', '有更新', '跳过'
          git_action_ansi(rendered, 36)
        when '成功', '正常', '通过', '已同步', '已暂存', '已提交', '已推送', '已继续', '已放弃', '已切换', '已合并', '已储藏', '已恢复', '已清理', '已更新'
          git_action_ansi(rendered, 32)
        when '失败', '缺失', '非Git', 'dirty', 'detached'
          git_action_ansi(rendered, 31)
        when '预览', '未知', '列表'
          git_action_ansi(rendered, 33)
        else
          rendered
        end
      end

      def git_action_ansi(text, code)
        "\e[#{code}m#{text}\e[0m"
      end

      def git_action_color_enabled?
        ENV['NO_COLOR'].to_s.empty? && ($stdout.tty? || ENV['COCOAPODS_PODX_COLOR'].to_s == '1')
      end

      def git_action_strip_ansi(value)
        value.to_s.gsub(/\e\[[0-9;]*m/, '')
      end

      def git_short_head(path)
        stdout, status = Open3.capture2e('git', '-C', path, 'rev-parse', '--short=6', 'HEAD')
        status.success? ? stdout.strip : '-'
      end

      def git_full_head(path)
        stdout, status = Open3.capture2e('git', '-C', path, 'rev-parse', 'HEAD')
        status.success? ? stdout.strip : ''
      end

      def git_remote_head(path, branch)
        stdout, status = Open3.capture2e('git', '-C', path, 'rev-parse', "refs/remotes/origin/#{branch}")
        status.success? ? stdout.strip : ''
      end

      def git_ahead_count(path, branch)
        remote_ref = "refs/remotes/origin/#{branch}"
        return nil unless git_ref_exists?(path, remote_ref)

        stdout, status = Open3.capture2('git', '-C', path, 'rev-list', '--count', "#{remote_ref}..HEAD")
        return nil unless status.success?

        stdout.to_i
      rescue
        nil
      end

      def git_stash_lines(path)
        stdout, status = Open3.capture2('git', '-C', path, 'stash', 'list')
        return [] unless status.success?

        stdout.lines.map(&:chomp).reject(&:empty?)
      end

      def git_commit_summary(path, commit)
        hash = commit.to_s.strip
        return '-' if hash.empty? || hash == '-'

        stdout, status = Open3.capture2('git', '-C', path, 'log', '-1', '--pretty=%s', hash)
        message = status.success? ? stdout.strip : ''
        message.empty? ? hash : "#{hash} #{git_action_summary(message, 50)}"
      end

    end
  end
end
