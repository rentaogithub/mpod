require 'fileutils'
require 'json'
require 'time'
require_relative '../rules'

module CocoapodsPodx
  module Commands
    module GitHooks
      def install_git_hooks(entries)
        repos = hook_repos(entries)
        rows = []
        installed_count = 0
        skipped_count = 0

        print_hook_rules
        Pod::UI.puts '【hooks 提示】未检测到 Podfile.overlay 本地组件，仅处理主仓库。' if entries.empty?

        repos.each do |repo|
          name = repo[:name]
          path = repo[:path]

          unless File.directory?(path)
            rows << [name, '缺失', '-']
            skipped_count += 1
            next
          end

          unless git_work_tree?(path)
            rows << [name, '非Git', '-']
            skipped_count += 1
            next
          end

          files = protected_commit_files_for_repo(name)
          if files.empty?
            next
          end

          if @dry_run
            rows << [name, '预览', files.join(', ')]
            installed_count += 1
            next
          end

          install_protected_file_hooks(path, files)
          rows << [name, '已安装', files.join(', ')]
          installed_count += 1
        rescue => e
          rows << [name, '失败', e.message]
          skipped_count += 1
        end

        git_action_print_table("hooks #{'dry-run ' if @dry_run}结果", %w[仓库 状态 保护文件], rows)
        Pod::UI.puts "【hooks 汇总】处理 #{installed_count} 个，跳过 #{skipped_count} 个"
      end

      def print_hook_rules
        git_action_print_table('hooks 规则', %w[规则 来源 内容 入口], podx_rules.summaries)
      end

      def show_podx_rules
        git_action_print_table('podx rules', %w[规则 来源 内容 入口], podx_rules.summaries)
      end

      def run_rules_command
        command = @pod_names.shift.to_s
        command = 'list' if command.empty?

        case command
        when 'list'
          show_podx_rules
        when 'check'
          check_podx_rules
        when 'sync'
          sync_podx_rules
        when 'snapshot'
          snapshot_podx_rules
        when 'ci'
          ci_podx_rules
        else
          raise Pod::Informative, "未知 rules 命令：#{command}，支持：podx rules、podx rules check、podx rules sync、podx rules snapshot、podx rules ci"
        end
      end

      def check_podx_rules
        rows = podx_rules_gitignore_rows
        git_action_print_table('rules check', %w[规则 状态 说明], rows)
        missing = rows.select { |row| row[1] == '缺失' }
        Pod::UI.puts "【rules check】缺失 #{missing.size} 个"
        raise Pod::Informative, 'rules check 失败，请执行 podx rules sync 补齐 .gitignore' if missing.any?
      end

      def sync_podx_rules
        rows = podx_rules_gitignore_rows
        missing_rules = rows.select { |row| row[1] == '缺失' }.map(&:first)
        write_podx_rules_gitignore(missing_rules) if missing_rules.any?
        updated_rows = missing_rules.empty? ? rows : podx_rules_gitignore_rows
        git_action_print_table('rules sync', %w[规则 状态 说明], updated_rows)
        Pod::UI.puts "【rules sync】补齐 #{missing_rules.size} 个"
      end

      def snapshot_podx_rules
        write_podx_rules_snapshot
        git_action_print_table('rules snapshot', %w[项目 状态 路径], [['rules', '已生成', podx_rules_snapshot_path]])
        Pod::UI.puts "【rules snapshot】#{podx_rules_snapshot_path}"
      end

      def ci_podx_rules
        payload = write_podx_rules_snapshot
        rows = [
          ['rules', payload[:status], podx_rules_snapshot_path]
        ]
        git_action_print_table('rules ci', %w[项目 状态 路径], rows)
        Pod::UI.puts "【rules ci】#{payload[:status]} missing #{payload[:missing_count]}"
        raise Pod::Informative, 'rules ci 失败，请执行 podx rules sync 补齐 .gitignore' if payload[:status] != 'pass'
      end

      def write_podx_rules_snapshot
        payload = podx_rules_snapshot_payload
        FileUtils.mkdir_p(File.dirname(podx_rules_snapshot_path))
        File.write(podx_rules_snapshot_path, JSON.pretty_generate(payload))
        payload
      end

      def podx_rules_snapshot_payload
        rows = podx_rules_gitignore_rows
        missing = rows.select { |row| row[1] == '缺失' }.map(&:first)
        {
          generated_at: Time.now.utc.iso8601,
          status: missing.empty? ? 'pass' : 'fail',
          missing_count: missing.length,
          missing_gitignore_rules: missing,
          gitignore_path: podx_rules_gitignore_path,
          summaries: podx_rules.summaries.map do |row|
            {
              rule: row[0],
              source: row[1],
              content: row[2],
              entry: row[3]
            }
          end,
          local_artifacts: rows.map do |row|
            {
              rule: row[0],
              status: row[1],
              path: row[2]
            }
          end
        }
      end

      def podx_rules_gitignore_rows
        existing = File.exist?(podx_rules_gitignore_path) ? File.read(podx_rules_gitignore_path) : ''
        missing = podx_rules.local_artifacts.missing_gitignore_rules(existing)
        podx_rules.local_artifacts.gitignore_rules.map do |rule|
          if missing.include?(rule)
            [rule, '缺失', podx_rules_gitignore_path]
          else
            [rule, '存在', podx_rules_gitignore_path]
          end
        end
      end

      def write_podx_rules_gitignore(rules)
        path = podx_rules_gitignore_path
        existing = File.exist?(path) ? File.read(path) : ''
        content = existing.dup
        content << "\n" unless content.empty? || content.end_with?("\n")
        content << "\n" unless content.empty? || content.end_with?("\n\n")
        content << "# podx local runtime artifacts\n" unless content.include?('# podx local runtime artifacts')
        content << rules.join("\n")
        content << "\n"
        File.write(path, content)
      end

      def podx_rules_gitignore_path
        File.join(project_directory, '.gitignore')
      end

      def podx_rules_snapshot_path
        File.join(project_directory, '.podx', 'rules_snapshot.json')
      end

      def protected_commit_files
        commit_protection_rule.protected_files
      end

      def protected_commit_files_for_repo(name)
        scope = name.to_s == 'main' ? :main : :component
        commit_protection_rule.protected_files_for(scope: scope)
      end

      def hook_repos(entries)
        [{ name: 'main', path: project_directory }] + entries.map do |entry|
          { name: entry[:name], path: local_repo_path_for(entry[:name]) }
        end
      end

      def install_protected_file_hooks(path, files)
        install_pre_commit_hook(path, files)
        install_pre_merge_commit_hook(path, files)
        install_post_commit_hook(path, files)
        install_post_merge_hook(path, files)
        install_pre_push_hook(path, files)
        configure_git_hooks_path(path)
      end

      def install_pre_commit_hook(path, files)
        hooks_dir = versioned_hooks_dir(path)
        FileUtils.mkdir_p(hooks_dir)
        hook_path = File.join(hooks_dir, 'pre-commit')
        existing = existing_hook_content(path, hook_path, 'pre-commit')
        updated = upsert_podx_hook(existing, files)
        File.write(hook_path, updated)
        FileUtils.chmod('+x', hook_path)
      end

      def install_pre_merge_commit_hook(path, files)
        hooks_dir = versioned_hooks_dir(path)
        FileUtils.mkdir_p(hooks_dir)
        hook_path = File.join(hooks_dir, 'pre-merge-commit')
        existing = existing_hook_content(path, hook_path, 'pre-merge-commit')
        updated = upsert_podx_hook(existing, files)
        File.write(hook_path, updated)
        FileUtils.chmod('+x', hook_path)
      end

      def install_post_commit_hook(path, files)
        hooks_dir = versioned_hooks_dir(path)
        FileUtils.mkdir_p(hooks_dir)
        hook_path = File.join(hooks_dir, 'post-commit')
        existing = existing_hook_content(path, hook_path, 'post-commit')
        updated = upsert_podx_post_commit_hook(existing, files)
        File.write(hook_path, updated)
        FileUtils.chmod('+x', hook_path)
      end

      def install_post_merge_hook(path, files)
        hooks_dir = versioned_hooks_dir(path)
        FileUtils.mkdir_p(hooks_dir)
        hook_path = File.join(hooks_dir, 'post-merge')
        existing = existing_hook_content(path, hook_path, 'post-merge')
        updated = upsert_podx_post_merge_hook(existing, files)
        File.write(hook_path, updated)
        FileUtils.chmod('+x', hook_path)
      end

      def install_pre_push_hook(path, files)
        hooks_dir = versioned_hooks_dir(path)
        FileUtils.mkdir_p(hooks_dir)
        hook_path = File.join(hooks_dir, 'pre-push')
        existing = existing_hook_content(path, hook_path, 'pre-push')
        updated = upsert_podx_pre_push_hook(existing, files)
        File.write(hook_path, updated)
        FileUtils.chmod('+x', hook_path)
      end

      def versioned_hooks_dir(path)
        File.join(path, '.githooks')
      end

      def existing_hook_content(path, hook_path, hook_name)
        return File.read(hook_path) if File.exist?(hook_path)

        legacy_hook_path = File.join(path, '.git', 'hooks', hook_name)
        return File.read(legacy_hook_path) if File.exist?(legacy_hook_path)

        "#!/bin/sh\n"
      end

      def configure_git_hooks_path(path)
        run_git!(path, 'config', 'core.hooksPath', '.githooks')
      end

      def upsert_podx_hook(content, files)
        base = content.to_s.empty? ? "#!/bin/sh\n" : content.to_s
        base = "#!/bin/sh\n#{base}" unless base.start_with?('#!')
        block = podx_pre_commit_hook_block(files)

        pattern = /#{Regexp.escape(commit_protection_rule.hook_marker_begin)}.*?#{Regexp.escape(commit_protection_rule.hook_marker_end)}\n?/m
        if base.match?(pattern)
          base.sub(pattern, block)
        else
          "#{base.chomp}\n\n#{block}"
        end
      end

      def upsert_podx_post_merge_hook(content, files)
        base = content.to_s.empty? ? "#!/bin/sh\n" : content.to_s
        base = "#!/bin/sh\n#{base}" unless base.start_with?('#!')
        block = podx_post_merge_hook_block(files)
        rule = commit_protection_rule

        pattern = /#{Regexp.escape(rule.post_merge_hook_marker_begin)}.*?#{Regexp.escape(rule.post_merge_hook_marker_end)}\n?/m
        if base.match?(pattern)
          base.sub(pattern, block)
        else
          "#{base.chomp}\n\n#{block}"
        end
      end

      def upsert_podx_pre_push_hook(content, files)
        base = content.to_s.empty? ? "#!/bin/sh\n" : content.to_s
        base = "#!/bin/sh\n#{base}" unless base.start_with?('#!')
        block = podx_pre_push_hook_block(files)
        rule = commit_protection_rule

        pattern = /#{Regexp.escape(rule.pre_push_hook_marker_begin)}.*?#{Regexp.escape(rule.pre_push_hook_marker_end)}\n?/m
        if base.match?(pattern)
          base.sub(pattern, block)
        else
          "#{base.chomp}\n\n#{block}"
        end
      end

      def upsert_podx_post_commit_hook(content, files)
        base = content.to_s.empty? ? "#!/bin/sh\n" : content.to_s
        base = "#!/bin/sh\n#{base}" unless base.start_with?('#!')
        block = podx_post_commit_hook_block(files)
        rule = commit_protection_rule

        pattern = /#{Regexp.escape(rule.post_commit_hook_marker_begin)}.*?#{Regexp.escape(rule.post_commit_hook_marker_end)}\n?/m
        if base.match?(pattern)
          base.sub(pattern, block)
        else
          "#{base.chomp}\n\n#{block}"
        end
      end

      def podx_pre_commit_hook_block(files)
        quoted_files = protected_files_shell_words(files)
        rule = commit_protection_rule
        <<~SH
          #{rule.hook_marker_begin}
          if [ "$#{rule.allow_env}" = "#{rule.allow_context}" ]; then
            exit 0
          fi

          protected_files="#{quoted_files}"
          changed_files="$(git diff --cached --name-only)"

          for changed_file in $changed_files; do
            changed_basename="$(basename "$changed_file")"
            for protected_file in $protected_files; do
              if [ "$changed_basename" = "$protected_file" ]; then
                echo "[拒绝提交] 不允许提交 $changed_file"
                echo "请先执行：git restore --staged \\"$changed_file\\" && git restore \\"$changed_file\\""
                exit 1
              fi
            done
          done
          #{rule.hook_marker_end}
        SH
      end

      def podx_post_merge_hook_block(files)
        quoted_files = protected_files_shell_words(files)
        rule = commit_protection_rule
        <<~SH
          #{rule.post_merge_hook_marker_begin}
          if [ "$#{rule.allow_env}" = "#{rule.allow_context}" ]; then
            exit 0
          fi

          if ! git rev-parse -q --verify ORIG_HEAD >/dev/null 2>&1; then
            exit 0
          fi

          protected_files="#{quoted_files}"

          for protected_file in $protected_files; do
            if git diff --quiet ORIG_HEAD HEAD -- "$protected_file"; then
              continue
            fi

            if git cat-file -e "ORIG_HEAD:$protected_file" 2>/dev/null; then
              git checkout ORIG_HEAD -- "$protected_file"
              echo "[保护文件还原] pull/merge 后已还原 $protected_file"
            else
              git rm -f --quiet "$protected_file" 2>/dev/null || rm -f "$protected_file"
              echo "[保护文件还原] pull/merge 后已移除新增的 $protected_file"
            fi
          done
          #{rule.post_merge_hook_marker_end}
        SH
      end

      def podx_pre_push_hook_block(files)
        quoted_files = protected_files_shell_words(files)
        rule = commit_protection_rule
        <<~SH
          #{rule.pre_push_hook_marker_begin}
          if [ "$#{rule.allow_env}" = "#{rule.allow_context}" ]; then
            exit 0
          fi

          protected_files="#{quoted_files}"
          zero_sha="0000000000000000000000000000000000000000"

          while read local_ref local_sha remote_ref remote_sha; do
            [ -n "$local_sha" ] || continue
            [ "$local_sha" != "$zero_sha" ] || continue
            [ "$remote_sha" != "$zero_sha" ] || continue

            changed_files="$(git diff --name-only "$remote_sha" "$local_sha" -- 2>/dev/null)"
            for changed_file in $changed_files; do
              changed_basename="$(basename "$changed_file")"
              for protected_file in $protected_files; do
                if [ "$changed_basename" = "$protected_file" ]; then
                  echo "[拒绝推送] 不允许推送包含 $changed_file 修改的提交"
                  echo "只有 mgit publish 或 mgit commit -edit $protected_file 允许提交受保护文件。"
                  exit 1
                fi
              done
            done
          done
          #{rule.pre_push_hook_marker_end}
        SH
      end

      def podx_post_commit_hook_block(files)
        quoted_files = protected_files_shell_words(files)
        rule = commit_protection_rule
        <<~SH
          #{rule.post_commit_hook_marker_begin}
          if [ "$#{rule.allow_env}" = "#{rule.allow_context}" ]; then
            exit 0
          fi

          cherry_pick_head="$(git rev-parse --git-path CHERRY_PICK_HEAD 2>/dev/null)"
          if [ ! -f "$cherry_pick_head" ]; then
            exit 0
          fi

          if ! git rev-parse -q --verify HEAD^ >/dev/null 2>&1; then
            exit 0
          fi

          protected_files="#{quoted_files}"
          changed_files="$(git diff-tree --no-commit-id --name-only -r HEAD^ HEAD)"
          matched_files=""

          for changed_file in $changed_files; do
            changed_basename="$(basename "$changed_file")"
            for protected_file in $protected_files; do
              if [ "$changed_basename" = "$protected_file" ]; then
                matched_files="$matched_files $changed_file"
              fi
            done
          done

          [ -n "$matched_files" ] || exit 0

          echo "[拒绝 cherry-pick] cherry-pick 提交包含受保护文件:$matched_files"
          echo "已回退本次 cherry-pick 提交，并还原受保护文件。"

          git reset --soft HEAD^
          for protected_file in $protected_files; do
            if git cat-file -e "HEAD:$protected_file" 2>/dev/null; then
              git checkout HEAD -- "$protected_file"
              git reset -q HEAD -- "$protected_file"
            else
              git rm -f --quiet -- "$protected_file" 2>/dev/null || rm -f "$protected_file"
            fi
          done
          #{rule.post_commit_hook_marker_end}
        SH
      end

      def protected_files_shell_words(files)
        files.map(&:to_s).map { |file| file.gsub(/["\\$`]/) { |char| "\\#{char}" } }.join(' ')
      end

      def commit_protection_rule
        @commit_protection_rule ||= podx_rules.commit_protection
      end

      def podx_rules
        path = respond_to?(:config_path, true) ? config_path : nil
        @podx_rules ||= CocoapodsPodx::Rules.engine(config_path: path)
      end
    end
  end
end
