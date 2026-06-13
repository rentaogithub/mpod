require 'fileutils'
require 'cgi'
require 'net/http'
require 'tmpdir'
require 'uri'
require_relative '../rules'

module CocoapodsPodx
  module Commands
    module MgitPublish
      def publish_git_branches
        publish_started_at = Time.now
        target_branch = @pod_names.first.to_s.strip
        raise Pod::Informative, '请指定目标分支，例如：mgit publish release/5.14.2' if target_branch.empty?
        validate_mgit_publish_target_branch!(target_branch)

        extra_args = @pod_names.drop(1)
        raise Pod::Informative, "mgit publish 只支持一个目标分支，无法识别：#{extra_args.join(' ')}" if extra_args.any?

        publish_config = mgit_publish_config
        base_branch = @git_publish_base_branch || publish_config[:base_branch] || 'develop'
        base_branch = base_branch.to_s.strip
        base_branch = 'develop' if base_branch.empty?
        raise Pod::Informative, '目标分支不能和基准分支相同' if target_branch == base_branch

        push_mode = @git_publish_push_mode.to_s.strip
        push_mode = 'normal' if push_mode.empty?
        unless %w[normal skip set-upstream].include?(push_mode)
          raise Pod::Informative, 'push-mode 只能是 normal、skip、set-upstream'
        end

        configured_work_dir = publish_config[:work_dir] || '.mgit-publish'
        raw_work_dir = @git_publish_work_dir.to_s.strip.empty? ? configured_work_dir : @git_publish_work_dir
        work_dir = File.expand_path(raw_work_dir, project_directory)
        repos = mgit_publish_repos

        release_version = mgit_publish_release_version(target_branch)
        release_build = release_version && mgit_publish_build_number(release_version)

        failures = []
        done_count = 0
        publish_rows = []

        FileUtils.mkdir_p(work_dir) unless @dry_run
        Pod::UI.puts @dry_run ? "mgit publish #{target_branch} 预览中..." : "mgit publish #{target_branch} 执行中..."

        repos.each do |repo|
          name = repo[:name]
          url = repo[:url]
          repo_dir = File.join(work_dir, name)

          begin
            if @dry_run
              changes = []
              if mgit_publish_main_repo?(name)
                changes << 'Podfile branch'
                changes << "version #{release_version}(#{release_build})" if release_version
              end
              publish_rows << [
                name,
                base_branch,
                target_branch,
                changes.empty? ? '-' : changes.join(', '),
                push_mode == 'skip' ? 'skip' : push_mode,
                'dry-run',
              ]
              done_count += 1
              next
            end

            unless mgit_publish_main_repo?(name)
              mgit_publish_push_remote_repo_branch(url, base_branch, target_branch, push_mode)
              publish_rows << [name, base_branch, target_branch, '-', push_mode == 'skip' ? 'skip' : 'remote', 'ok']
              done_count += 1
              next
            end

            FileUtils.rm_rf(repo_dir) if File.exist?(repo_dir)
            run_git!(work_dir, 'clone', url, repo_dir)

            run_git!(repo_dir, 'fetch', 'origin', base_branch)

            checkout_branch!(repo_dir, base_branch)

            base_changed_files = mgit_publish_update_base_project(repo_dir, base_branch, release_version, release_build)
            if base_changed_files.any? && push_mode != 'skip'
              run_git!(repo_dir, 'push', 'origin', base_branch)
            end

            run_git!(repo_dir, 'checkout', '-B', target_branch, base_branch)

            target_changed_files = mgit_publish_main_repo?(name) ? mgit_publish_update_main_project(repo_dir, target_branch) : []
            changed_files = base_changed_files.map { |file| "#{base_branch}:#{file}" } +
                            target_changed_files.map { |file| "#{target_branch}:#{file}" }

            case push_mode
            when 'normal'
              run_git!(repo_dir, 'push', 'origin', target_branch)
            when 'set-upstream'
              run_git!(repo_dir, 'push', '--set-upstream', 'origin', target_branch)
            when 'skip'
            end

            publish_rows << [
              name,
              base_branch,
              target_branch,
              changed_files.empty? ? '-' : changed_files.join(', '),
              push_mode == 'skip' ? 'skip' : push_mode,
              'ok',
            ]
            done_count += 1
          rescue => e
            publish_rows << [name, base_branch, target_branch, '-', push_mode, "failed: #{e.message}"]
            failures << "#{name}: #{e.message}"
          end
        end

        mgit_publish_print_table(
          @dry_run ? 'mgit publish 预览' : 'mgit publish 仓库',
          publish_rows,
          headers: ['仓库', '基准分支', '发布分支', '变更', '推送', '结果']
        )

        if failures.any?
          raise Pod::Informative, "mgit publish [failed] #{failures.size}\n#{failures.join("\n")}"
        end

        mgit_publish_cleanup_work_dir(work_dir) unless @dry_run

        unless @dry_run
          checkout_rows = []
          checkout_rows << mgit_publish_checkout_project_repo(target_branch)
          checkout_rows.concat(mgit_publish_sync_local_repos(target_branch))
          checkout_rows.compact!
        end

        Pod::UI.puts @dry_run ? "mgit publish #{target_branch} 预览完成 #{done_count}" : "mgit publish #{target_branch} 执行完成 #{done_count}"
        Pod::UI.puts "【publish 耗时】#{mgit_publish_format_duration(Time.now - publish_started_at)}"
      end

      def mgit_publish_format_duration(seconds)
        total_seconds = [seconds.to_f.round, 0].max
        minutes = total_seconds / 60
        remaining_seconds = total_seconds % 60
        return "#{remaining_seconds}s" if minutes.zero?

        "#{minutes}m#{remaining_seconds.to_s.rjust(2, '0')}s"
      end

      def mgit_publish_cleanup_work_dir(work_dir)
        return if work_dir.to_s.strip.empty?
        return unless File.directory?(work_dir)

        Dir.children(work_dir).each do |child|
          FileUtils.rm_rf(File.join(work_dir, child))
        end
      rescue
        nil
      end

      def mgit_publish_push_remote_repo_branch(url, base_branch, target_branch, push_mode)
        return mgit_publish_remote_branch_hash(url, base_branch) if push_mode == 'skip'

        return if mgit_publish_create_remote_branch_via_api(url, base_branch, target_branch)

        mgit_publish_push_remote_repo_branch_via_git(url, base_branch, target_branch)
      end

      def mgit_publish_push_remote_repo_branch_via_git(url, base_branch, target_branch)
        mgit_publish_remote_branch_hash(url, base_branch)

        Dir.mktmpdir('cocoapods-podx-mgit-publish-remote') do |repo_dir|
          run_git!(repo_dir, 'init', '-q')
          run_git!(repo_dir, 'fetch', '--depth', '1', url, "refs/heads/#{base_branch}")
          run_git!(repo_dir, 'push', url, "FETCH_HEAD:refs/heads/#{target_branch}")
        end
      end

      def mgit_publish_remote_branch_hash(url, branch)
        output = run_git!(project_directory, 'ls-remote', url, "refs/heads/#{branch}")
        hash = output.to_s.split(/\s+/).first.to_s
        raise "远端分支不存在：#{branch}" if hash.empty?

        hash
      end

      def mgit_publish_create_remote_branch_via_api(url, base_branch, target_branch)
        uri = mgit_publish_gitlab_create_branch_uri(url)
        return false unless uri

        token = ENV['COCOAPODS_PODX_GIT_TOKEN'].to_s.strip
        token = ENV['GITLAB_TOKEN'].to_s.strip if token.empty?
        token = ENV['PRIVATE_TOKEN'].to_s.strip if token.empty?
        user = ENV['COCOAPODS_PODX_GIT_USER'].to_s.strip
        password = ENV['COCOAPODS_PODX_GIT_PASSWORD'].to_s.strip
        return false if token.empty? && (user.empty? || password.empty?)

        request = Net::HTTP::Post.new(uri)
        request['PRIVATE-TOKEN'] = token unless token.empty?
        request.basic_auth(user, password) if token.empty? && !user.empty?
        request.set_form_data('branch' => target_branch, 'ref' => base_branch)
        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == 'https', open_timeout: 5, read_timeout: 15) do |http|
          http.request(request)
        end

        return true if response.is_a?(Net::HTTPSuccess)

        body = response.body.to_s
        if response.code.to_i == 401
          return false
        end

        if response.code.to_i == 403
          return false
        end

        if response.code.to_i == 400 && body.match?(/Branch already exists|already exists/i)
          raise "远端发布分支已存在：#{target_branch}"
        end

        raise "远端 API 创建分支失败：HTTP #{response.code} #{body[0, 120]}"
      rescue URI::InvalidURIError
        false
      end

      def mgit_publish_gitlab_create_branch_uri(url)
        uri = URI(url.to_s)
        return nil unless %w[http https].include?(uri.scheme)

        project_path = uri.path.to_s.sub(%r{\A/}, '').sub(/\.git\z/, '')
        return nil if project_path.empty?

        api_path = "/api/v4/projects/#{CGI.escape(project_path)}/repository/branches"
        default_port = (uri.scheme == 'https' ? 443 : 80)
        host = uri.port == default_port ? uri.host : "#{uri.host}:#{uri.port}"
        URI("#{uri.scheme}://#{host}#{api_path}")
      end

      def mgit_publish_sync_overlay_repos(target_branch)
        mgit_publish_sync_local_repos(target_branch)
      end

      def mgit_publish_sync_local_repos(target_branch)
        return [] unless respond_to?(:load_entries, true) && respond_to?(:update_local_repo, true)

        names = mgit_publish_local_repo_names
        return [] if names.empty?

        rows = []
        failures = []

        names.each do |name|
          begin
            if @dry_run
              rows << [name, '-', target_branch, 'dry-run']
            else
              updated = update_local_repo(name, dry_run: false, pull: true, expected_branch: target_branch)
              rows << [name, '-', target_branch, updated ? 'ok' : 'skip']
            end
          rescue => e
            rows << [name, '-', target_branch, "failed: #{e.message}"]
            failures << "#{name}: #{e.message}"
          end
        end

        if failures.any?
          raise Pod::Informative, "本地组件切换发布分支失败：\n#{failures.join("\n")}"
        end

        rows
      end

      def mgit_publish_local_repo_names
        names = []
        repo_names = mgit_publish_repos.map { |repo| repo[:name].to_s }.reject(&:empty?)
        main_repo = mgit_publish_config[:main_repo].to_s

        repo_names.each do |repo_name|
          next if repo_name == main_repo

          names.concat(mgit_publish_local_names_for_repo(repo_name))
        end

        names.concat(mgit_publish_overlay_local_repo_names)

        names.map(&:to_s).reject(&:empty?).uniq
      end

      def mgit_publish_overlay_local_repo_names
        return [] unless respond_to?(:load_entries, true)

        load_entries.map { |entry| entry[:name].to_s }
      end

      def mgit_publish_local_names_for_repo(repo_name)
        normalized_repo = repo_name.to_s.downcase
        entries = CocoapodsPodx::Runtime.managed_pod_entries
        matches = entries.select do |entry|
          raw_name = entry[:name].to_s
          group_name = entry[:group_name].to_s
          remote_name = (entry[:remote_name] || raw_name).to_s
          local_name = (entry[:local_name] || '').to_s

          [
            raw_name,
            group_name,
            remote_name,
            local_name,
            CocoapodsPodx::Runtime.local_repo_folder_name_for(raw_name)
          ].any? { |value| value.to_s.downcase == normalized_repo }
        end

        return [repo_name] if matches.empty?

        matches.map do |entry|
          group_name = entry[:group_name].to_s
          target_name = CocoapodsPodx::Runtime.config[:target_name].to_s
          if !group_name.empty? && group_name != 'nn_ios' && group_name != target_name
            group_name
          else
            entry[:name]
          end
        end
      end

      def mgit_publish_checkout_project_repo(target_branch)
        return nil unless respond_to?(:project_directory, true) && git_work_tree?(project_directory)

        name = File.basename(project_directory)
        from_branch = git_branch_for(project_directory) || 'detached'
        return [name, from_branch, target_branch, 'skip same'] if from_branch == target_branch
        return [name, from_branch, target_branch, 'dry-run'] if @dry_run
        return [name, from_branch, target_branch, 'skip dirty'] if git_dirty?(project_directory)

        run_git!(project_directory, 'fetch', 'origin', target_branch)
        checkout_branch!(project_directory, target_branch)
        [name, from_branch, target_branch, 'ok']
      end

      def mgit_publish_update_base_project(repo_dir, base_branch, release_version, release_build)
        changed_files = []
        project_file = mgit_publish_version_config[:project_file]
        if mgit_publish_version_update_enabled? && release_version && mgit_publish_update_project_version(repo_dir, release_version, release_build)
          changed_files << project_file
        end
        return [] if changed_files.empty? || !git_dirty?(repo_dir)

        run_git!(repo_dir, 'add', *changed_files)
        message = "chore: update version to #{release_version}"
        message += "(#{release_build})" if release_build
        message += " for #{base_branch}"
        with_mgit_publish_protected_commit_allowed do
          run_git!(repo_dir, 'commit', '-m', message)
        end
        changed_files
      end

      def mgit_publish_update_main_project(repo_dir, target_branch)
        changed_files = []
        changed_files << 'Podfile' if mgit_publish_update_podfile_branch_enabled? && mgit_publish_update_podfile_branch(repo_dir, target_branch)
        return [] if changed_files.empty? || !git_dirty?(repo_dir)

        run_git!(repo_dir, 'add', *changed_files)
        message = "chore: update publish config to #{target_branch}"
        with_mgit_publish_protected_commit_allowed do
          run_git!(repo_dir, 'commit', '-m', message)
        end
        changed_files
      end

      def with_mgit_publish_protected_commit_allowed
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

      def mgit_publish_print_table(title, rows, headers:)
        rows = rows.map { |row| row.map { |value| mgit_publish_cell(value) } }
        headers = headers.map { |value| mgit_publish_cell(value) }
        widths = headers.each_index.map do |index|
          ([mgit_publish_display_width(headers[index])] + rows.map { |row| mgit_publish_display_width(row[index]) }).max
        end

        Pod::UI.puts "【#{title}】"
        separator = "+#{widths.map { |width| '-' * (width + 2) }.join('+')}+"
        Pod::UI.puts separator
        Pod::UI.puts "| #{headers.each_with_index.map { |value, index| mgit_publish_pad_display(value, widths[index]) }.join(' | ')} |"
        Pod::UI.puts separator
        rows.each do |row|
          Pod::UI.puts "| #{row.each_with_index.map { |value, index| mgit_publish_pad_display(value, widths[index]) }.join(' | ')} |"
        end
        Pod::UI.puts separator
      end

      def mgit_publish_cell(value)
        text = value.to_s
        text.empty? ? '-' : text.gsub(/\s+/, ' ').strip
      end

      def mgit_publish_display_width(value)
        value.to_s.each_char.sum { |char| char.bytesize == 1 ? 1 : 2 }
      end

      def mgit_publish_pad_display(value, width)
        text = value.to_s
        text + (' ' * [width - mgit_publish_display_width(text), 0].max)
      end

      def mgit_publish_update_podfile_branch(repo_dir, target_branch)
        podfile = File.join(repo_dir, 'Podfile')
        return false unless File.exist?(podfile)

        content = File.read(podfile)
        updated = content.gsub(/((?:branch\s*:|:branch\s*=>)\s*)['"][^'"]*['"]/) { "#{$1}'#{target_branch}'" }
        return false if updated == content

        File.write(podfile, updated)
        true
      end

      def mgit_publish_update_project_version(repo_dir, version, build)
        project_file = File.join(repo_dir, mgit_publish_version_config[:project_file])
        return false unless File.exist?(project_file)

        content = File.read(project_file)
        updated = content.gsub(/MARKETING_VERSION = \d+\.\d+\.\d+;/, "MARKETING_VERSION = #{version};")
        updated = updated.gsub(/CURRENT_PROJECT_VERSION = \d{6,};/, "CURRENT_PROJECT_VERSION = #{build};") if build
        return false if updated == content

        File.write(project_file, updated)
        true
      end

      def mgit_publish_release_version(branch)
        pattern_source = mgit_publish_version_config[:branch_pattern].to_s
        return nil if pattern_source.empty?

        pattern = Regexp.new(pattern_source)
        match = branch.match(pattern)
        match && match[1]
      end

      def validate_mgit_publish_target_branch!(branch)
        if mgit_publish_placeholder_branch?(branch)
          raise Pod::Informative, "发布分支不能使用示例占位符：#{branch}，请使用真实分支，例如：mgit publish release/5.14.2"
        end

        text = branch.to_s.strip
        raise Pod::Informative, "发布分支格式不正确：#{branch}" if text.empty? || text.start_with?('-') || text.match?(/\s/)
      end

      def mgit_publish_placeholder_branch?(branch)
        text = branch.to_s.strip
        return true if text.match?(/\A\[.+\]\z/)
        return true if %w[BRANCH VERSION BUILD NAME N].include?(text)
        return true if text.match?(%r{\Arelease/[a-z](?:\.[a-z])+\z}i)

        false
      end

      def mgit_publish_branch_pattern_label(pattern_source)
        pattern_source.include?('release/') ? 'release/x.x.x' : pattern_source
      end

      def mgit_publish_build_number(version)
        return nil unless mgit_publish_version_config[:build_number_strategy] == 'ios_semver'

        major, minor, patch = version.split('.').map(&:to_i)
        "#{major}0#{minor.to_s.rjust(2, '0')}#{patch.to_s.rjust(2, '0')}"
      end

      def mgit_publish_main_repo?(name = nil)
        main_repo = mgit_publish_config[:main_repo].to_s.strip
        return false if main_repo.empty?
        return true if name.nil?

        name.to_s == main_repo
      end

      def mgit_publish_update_podfile_branch_enabled?
        mgit_publish_config[:update_podfile_branch] == true
      end

      def mgit_publish_version_update_enabled?
        mgit_publish_version_config[:type] == 'ios_xcodeproj' && !mgit_publish_version_config[:project_file].to_s.strip.empty?
      end

      def mgit_publish_repos
        base_url = mgit_publish_git_base_url
        configured_repos = mgit_publish_config[:repos]
        return configured_repos.map { |repo| mgit_publish_repo_config(repo, base_url) } if configured_repos && configured_repos.any?

        repo_names = %w[
          nnios
          nnbusscom
          nnimmanager
          nnbascicommon
          nnapperance
          nncategory
          nnlogmodule
          nnnetwork
          nnrealreachability
          nnyytext
          nngeneral
          nnswiftscan
        ]

        repo_names.map { |name| mgit_publish_repo_config(name, base_url) }
      end

      def mgit_publish_git_base_url
        config = CocoapodsPodx::Runtime.config
        config = inferred_project_config if config[:git_base_url].to_s.strip.empty?
        base_url = config[:git_base_url].to_s.strip
        target_name = config[:target_name].to_s.strip
        unless base_url.empty?
          return base_url if target_name.empty? || base_url.end_with?("/#{target_name}")

          return "#{base_url}/#{target_name}"
        end

        'http://git.leigod.top/nn_ios'
      end

      def mgit_publish_config
        config = CocoapodsPodx::Runtime.config
        {
          work_dir: config[:publish_work_dir],
          base_branch: config[:publish_base_branch],
          repos: config[:publish_repos],
          main_repo: config[:publish_main_repo],
          update_podfile_branch: config[:publish_update_podfile_branch],
        }
      end

      def mgit_publish_version_config
        config = CocoapodsPodx::Runtime.config[:publish_version] || {}
        {
          type: config[:type].to_s,
          branch_pattern: config[:branch_pattern].to_s,
          project_file: config[:project_file].to_s,
          build_number_strategy: config[:build_number_strategy].to_s,
        }
      end

      def mgit_publish_repo_config(repo, base_url)
        if repo.is_a?(Hash)
          name = repo[:name].to_s
          url = repo[:url].to_s
          url = default_mgit_publish_repo_url(name, base_url) if url.empty?
          return { name: name, url: url }
        end

        name = repo.to_s
        { name: name, url: default_mgit_publish_repo_url(name, base_url) }
      end

      def default_mgit_publish_repo_url(name, base_url)
        main_remote = respond_to?(:git_remote_url, true) ? git_remote_url : nil
        name == 'nnios' ? (main_remote || "#{base_url}/#{name}.git") : "#{base_url}/#{name}.git"
      end
    end
  end
end
