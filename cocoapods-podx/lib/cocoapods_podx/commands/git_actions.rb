
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

          unless File.directory?(path)
            rows << [name, '-', 'missing', '-', path]
            skipped_count += 1
            next
          end

          unless git_work_tree?(path)
            rows << [name, '-', 'not-git', '-', path]
            skipped_count += 1
            next
          end

          branch = git_branch_for(path)
          status = git_status_lines(path)

          begin
            case action
            when 'status'
              if status.empty?
                rows << [name, branch || 'detached', 'clean', '-', path]
                skipped_count += 1
              else
                rows << [name, branch || 'detached', 'changed', git_changed_file_summary(status), path]
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
                run_git!(path, 'merge', '--no-edit', '--no-stat', "origin/#{@merge_branch}")
                after_commit = git_full_head(path)
                if before_commit != after_commit
                  rows << [name, branch, 'merged', git_commit_summary(path, after_commit), path]
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
              elsif git_dirty?(path)
                rows << [name, branch, '跳过', 'dirty', path]
                skipped_count += 1
              elsif @dry_run
                detail = align_state == :dry_run_checkout ? "checkout -> #{branch}; pull origin/#{branch}" : "pull origin/#{branch}"
                rows << [name, branch, '预览', detail, path]
                done_count += 1
              else
                before_commit = git_short_head(path)
                run_git!(path, 'pull', '--ff-only', 'origin', branch)
                after_commit = git_short_head(path)
                if before_commit != after_commit
                  rows << [name, branch, '有更新', git_commit_summary(path, after_commit), path]
                  done_count += 1
                else
                  rows << [name, branch, '无更新', '-', path]
                  skipped_count += 1
                end
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
                run_git!(path, 'fetch', 'origin', branch)
                local_commit = git_full_head(path)
                remote_commit = git_remote_head(path, branch)
                if !remote_commit.empty? && local_commit == remote_commit
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
          git_action_print_table("#{action} #{'dry-run ' if @dry_run}结果", %w[仓库 分支 更新状态 Commit], rows.map { |row| row.first(4) })
        elsif action == 'status'
          git_action_print_table("#{action} 结果", %w[仓库 分支 变更], rows.map { |row| git_status_table_row(row) })
        elsif action == 'stash'
          git_action_print_table("#{action} #{'dry-run ' if @dry_run}结果", %w[仓库 分支 变更], rows.map { |row| git_stash_table_row(row) })
        elsif %w[add checkout merge push].include?(action)
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
            rows << [name, branch, 'skip']
            skipped_count += 1
            next
          end

          if status.empty?
            rows << [name, branch, 'skip']
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
        repo, branch, status, detail = row
        change = status == 'clean' ? '-' : detail
        [repo, branch, change]
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

      def git_simple_action_table_row(row)
        repo, branch, status = row
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
        when 'up-to-date'
          '无更新'
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
          Pod::UI.puts "| #{row.each_with_index.map { |value, index| git_action_pad_display(value, widths[index]) }.join(' | ')} |"
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
        value.to_s.each_char.sum { |char| git_action_display_char_width(char) }
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

      def git_short_head(path)
        stdout, status = Open3.capture2('git', '-C', path, 'rev-parse', '--short=6', 'HEAD')
        status.success? ? stdout.strip : '-'
      end

      def git_full_head(path)
        stdout, status = Open3.capture2('git', '-C', path, 'rev-parse', 'HEAD')
        status.success? ? stdout.strip : ''
      end

      def git_remote_head(path, branch)
        stdout, status = Open3.capture2('git', '-C', path, 'rev-parse', "refs/remotes/origin/#{branch}")
        status.success? ? stdout.strip : ''
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
