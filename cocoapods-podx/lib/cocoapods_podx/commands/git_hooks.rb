require 'fileutils'
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
        install_post_merge_hook(path, files)
      end

      def install_pre_commit_hook(path, files)
        hooks_dir = File.join(path, '.git', 'hooks')
        FileUtils.mkdir_p(hooks_dir)
        hook_path = File.join(hooks_dir, 'pre-commit')
        existing = File.exist?(hook_path) ? File.read(hook_path) : "#!/bin/sh\n"
        updated = upsert_podx_hook(existing, files)
        File.write(hook_path, updated)
        FileUtils.chmod('+x', hook_path)
      end

      def install_post_merge_hook(path, files)
        hooks_dir = File.join(path, '.git', 'hooks')
        FileUtils.mkdir_p(hooks_dir)
        hook_path = File.join(hooks_dir, 'post-merge')
        existing = File.exist?(hook_path) ? File.read(hook_path) : "#!/bin/sh\n"
        updated = upsert_podx_post_merge_hook(existing, files)
        File.write(hook_path, updated)
        FileUtils.chmod('+x', hook_path)
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

      def podx_pre_commit_hook_block(files)
        quoted_files = files.map { |file| file.gsub("'", %q('"'"')) }.map { |file| "'#{file}'" }.join(' ')
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
        quoted_files = files.map { |file| file.gsub("'", %q('"'"')) }.map { |file| "'#{file}'" }.join(' ')
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
