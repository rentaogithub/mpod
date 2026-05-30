require 'digest'
require 'fileutils'
require 'net/http'
require 'open3'
require 'time'
require 'tmpdir'
require 'timeout'
require 'uri'
require_relative '../failure_case_store'

module CocoapodsPodx
  module Commands
    module JenkinsPublish
      class JenkinsConnectionError < StandardError; end
      class JenkinsAutoFixApplied < StandardError; end

      def publish_to_jenkins
        validate_jenkins_publish_context!
        job_profile = jenkins_publish_job_profile
        channels = @pod_names.empty? ? [job_profile[:default_channel]] : @pod_names

        branch = jenkins_publish_branch
        with_jenkins_publish_lock(job_profile, branch, channels) do
          channels.each do |channel|
            target = jenkins_deploy_target(channel)
            validate_jenkins_publish_target!(job_profile, target)
            validate_jenkins_publish_branch!(branch, target)
            run_publish_pipeline_gate_if_needed!(target)

            print_publish_header(branch, target)
            rows = publish_git_rows(branch)
            print_publish_git_table(rows)
            validate_publish_remote_release_branches!(branch, rows, target)
            params = jenkins_build_params(job_profile, branch, target)
            if @dry_run
              Pod::UI.puts '【打包结果】dry-run，不触发 Jenkins 打包'
            else
              print_jenkins_progress('等待 Jenkins 打包...')
              trigger_jenkins_build_with_auto_fix_retry(params, target[:name])
            end
          end
        end
      end

      def with_jenkins_publish_lock(job_profile, branch, channels)
        return yield if @dry_run || @skip_publish_lock

        FileUtils.mkdir_p(publish_lock_directory)
        lock_path = publish_lock_path(job_profile)
        File.open(lock_path, File::RDWR | File::CREAT, 0o644) do |lock|
          unless lock.flock(File::LOCK_EX | File::LOCK_NB)
            raise Pod::Informative, "当前工程已有 podx publish 正在执行：#{publish_lock_summary(lock_path)}。如确认需要并行触发，请加 --no-publish-lock。"
          end

          write_publish_lock(lock, job_profile, branch, channels)
          yield
        ensure
          FileUtils.rm_f(lock_path)
        end
      end

      def publish_lock_directory
        base_dir = respond_to?(:project_directory, true) ? project_directory : Dir.pwd
        File.join(base_dir, '.podx', 'locks')
      end

      def publish_lock_path(job_profile)
        File.join(publish_lock_directory, "publish-#{publish_lock_job_key(job_profile)}.lock")
      end

      def publish_lock_job_key(job_profile)
        job_profile.fetch(:job_name, configured_jenkins_job_name).to_s.gsub(/[^0-9A-Za-z._-]+/, '_')
      end

      def write_publish_lock(lock, job_profile, branch, channels)
        lock.rewind
        lock.truncate(0)
        lock.write([
          "pid=#{Process.pid}",
          "job=#{job_profile.fetch(:job_name, configured_jenkins_job_name)}",
          "branch=#{branch}",
          "channels=#{Array(channels).join(',')}",
          "started_at=#{Time.now.strftime('%Y-%m-%d %H:%M:%S')}",
        ].join("\n"))
        lock.write("\n")
        lock.flush
      end

      def publish_lock_summary(lock_path)
        return lock_path unless File.exist?(lock_path)

        data = File.read(lock_path)
        pid = data[/^pid=(.+)$/, 1]
        job = data[/^job=(.+)$/, 1]
        branch = data[/^branch=(.+)$/, 1]
        channels = data[/^channels=(.+)$/, 1]
        started_at = data[/^started_at=(.+)$/, 1]
        parts = []
        parts << "PID #{pid}" if pid && !pid.empty?
        parts << "job #{job}" if job && !job.empty?
        parts << "分支 #{branch}" if branch && !branch.empty?
        parts << "渠道 #{channels}" if channels && !channels.empty?
        parts << "开始时间 #{started_at}" if started_at && !started_at.empty?
        parts.empty? ? lock_path : parts.join('，')
      rescue
        lock_path
      end

      def sync_local_overlay_repos_after_publish(jenkins_branch)
        return unless respond_to?(:load_entries, true) && respond_to?(:update_local_repo, true)

        entries = load_entries
        return if entries.empty?

        target_branch = jenkins_branch.to_s.sub(%r{\Aorigin/}, '')
        rows = []
        failures = []

        entries.map { |entry| entry[:name] }.uniq.each do |name|
          begin
            updated = update_local_repo(name, dry_run: false, pull: true, expected_branch: target_branch, quiet: true)
            rows << [name, target_branch, updated ? '已同步' : '无更新']
          rescue => e
            rows << [name, target_branch, "失败：#{e.message}"]
            failures << "#{name}: #{e.message}"
          end
        end

        print_publish_overlay_sync_table(rows)
        raise Pod::Informative, "发布成功后本地组件切换发布分支失败：\n#{failures.join("\n")}" if failures.any?
      end

      def run_publish_pipeline_gate_if_needed!(target)
        mode = publish_pipeline_gate_mode(target)
        return if mode == 'off'
        raise Pod::Informative, '当前环境不支持 pipeline gate，请在 Podfile 工程中执行 podx publish，或使用 --no-pipeline-gate 跳过。' unless respond_to?(:pipeline_gate_rows, true)

        rows = pipeline_gate_rows
        git_action_print_table('publish pipeline gate', %w[维度 状态 建议], rows)
        failures = rows.select { |row| row[1] != '通过' }
        channel = target[:name].to_s
        Pod::UI.puts "【发布预检】#{channel} #{publish_pipeline_gate_mode_label(mode)} #{failures.empty? ? '通过' : "失败 #{failures.size} 个"}"
        return if failures.empty?
        return Pod::UI.puts('【发布预检】告警模式，继续发布') if mode == 'warn'

        raise Pod::Informative, '发布预检失败，请按建议修复后重试；如需临时跳过，请使用 --no-pipeline-gate。'
      end

      def publish_pipeline_gate_mode(target)
        return 'off' if @skip_publish_pipeline_gate
        return publish_pipeline_gate_strategy_mode(target) if @publish_pipeline_gate
        return publish_pipeline_gate_strategy_mode(target) if ENV['COCOAPODS_PODX_PUBLISH_PIPELINE_GATE'].to_s == '1'

        value = jenkins_project_config[:publish_pipeline_gate]
        return 'off' unless value == true || value.to_s == 'true' || value.to_s == '1'

        publish_pipeline_gate_strategy_mode(target)
      rescue
        'off'
      end

      def publish_pipeline_gate_strategy_mode(target)
        configured = publish_pipeline_gate_strategy[target_key_for_gate_strategy(target)]
        mode = configured.to_s.strip.downcase
        return mode if %w[off warn strict].include?(mode)

        default_publish_pipeline_gate_strategy[target_key_for_gate_strategy(target)]
      end

      def publish_pipeline_gate_strategy
        raw = jenkins_project_config[:publish_pipeline_gate_strategy]
        raw = {} unless raw.is_a?(Hash)
        raw.each_with_object({}) do |(key, value), memo|
          memo[key.to_s.strip.downcase] = value
        end
      end

      def default_publish_pipeline_gate_strategy
        {
          'pgyer' => 'warn',
          'testflight' => 'strict',
          'appstore' => 'strict',
          'framework' => 'warn'
        }
      end

      def target_key_for_gate_strategy(target)
        value = target[:value].to_s
        return 'pgyer' if value.match?(/Pgyer/i)
        return 'testflight' if value.match?(/TestFlight/i)
        return 'appstore' if value.match?(/AppStore/i)
        return 'framework' if target[:kind] == :framework

        target[:name].to_s.downcase
      end

      def publish_pipeline_gate_mode_label(mode)
        case mode
        when 'strict'
          '严格门禁'
        when 'warn'
          '告警门禁'
        else
          mode
        end
      end

      def jenkins_project_config
        return @jenkins_project_config if defined?(@jenkins_project_config)

        @jenkins_project_config = begin
          if defined?(CocoapodsPodx::Runtime)
            CocoapodsPodx::Runtime.configure(project_directory: jenkins_project_directory) if CocoapodsPodx::Runtime.respond_to?(:configure)
            CocoapodsPodx::Runtime.project_config
          else
            {}
          end
        rescue
          {}
        end
      end

      def print_publish_overlay_sync_table(rows)
        return if rows.empty?

        headers = %w[仓库 分支 结果]
        rows = rows.map { |row| row.map { |value| publish_overlay_sync_cell(value) } }
        widths = headers.each_index.map do |index|
          ([publish_overlay_sync_display_width(headers[index])] + rows.map { |row| publish_overlay_sync_display_width(row[index]) }).max
        end

        Pod::UI.puts '【本地组件同步】'
        separator = "+#{widths.map { |width| '-' * (width + 2) }.join('+')}+"
        Pod::UI.puts separator
        Pod::UI.puts "| #{headers.each_with_index.map { |value, index| publish_overlay_sync_pad_display(value, widths[index]) }.join(' | ')} |"
        Pod::UI.puts separator
        rows.each do |row|
          Pod::UI.puts "| #{row.each_with_index.map { |value, index| publish_overlay_sync_pad_display(value, widths[index]) }.join(' | ')} |"
        end
        Pod::UI.puts separator
      end

      def publish_overlay_sync_cell(value)
        text = value.to_s.gsub(/\s+/, ' ').strip
        text.empty? ? '-' : text
      end

      def publish_overlay_sync_display_width(value)
        value.to_s.each_char.sum { |char| char.bytesize == 1 ? 1 : 2 }
      end

      def publish_overlay_sync_pad_display(value, width)
        text = value.to_s
        text + (' ' * [width - publish_overlay_sync_display_width(text), 0].max)
      end

      def show_jenkins_build_log
        validate_jenkins_log_context!
        build = normalize_jenkins_log_build(@jenkins_log_build || @pod_names.first)
        log = fetch_jenkins_build_log(build, line_limit: @jenkins_log_lines)
        log_file = write_jenkins_log_file(build, log[:lines])

        Pod::UI.puts "【Jenkins日志】#{log[:log_uri]}"
        Pod::UI.puts "【日志文件】#{log_file}"
        open_jenkins_log_file(log_file)
      end

      def show_jenkins_build_history
        validate_jenkins_log_context!
        limit = jenkins_history_limit
        rows = fetch_jenkins_build_history(limit)

        Pod::UI.puts "【Jenkins任务】#{selected_jenkins_job_url}"
        Pod::UI.puts "【最近构建】#{limit}"
        print_jenkins_build_history_table(rows)
      end

      def doctor_jenkins_build
        validate_jenkins_log_context!
        build = normalize_jenkins_log_build(@jenkins_log_build || @pod_names.first)
        log = fetch_jenkins_build_log(build, line_limit: @jenkins_log_lines)
        log_file = write_jenkins_log_file(build, log[:lines])
        report = analyze_jenkins_failure(log[:lines])

        print_jenkins_failure_report(log, log_file, report)
        run_hermes_failure_analysis(log_file, report) if @jenkins_hermes_analysis
      end

      def fix_jenkins_build
        validate_jenkins_log_context!
        build = normalize_jenkins_log_build(@jenkins_log_build || @pod_names.first)
        log = fetch_jenkins_build_log(build, line_limit: @jenkins_log_lines)
        log_file = write_jenkins_log_file(build, log[:lines])
        report = analyze_jenkins_failure(log[:lines])
        actions = jenkins_fix_actions(report)

        print_jenkins_failure_report(log, log_file, report)
        if actions.empty?
          Pod::UI.puts '【修复动作】当前失败类型不适合半自动修复，请按修复建议人工处理。'
          return
        end

        actions.each do |action|
          Pod::UI.puts "【修复动作】#{action[:title]}"
          Pod::UI.puts "【执行命令】#{action[:command].join(' ')}" if action[:command]
          Pod::UI.puts "【执行目录】#{action[:chdir]}" if action[:chdir]
          if @dry_run
            Pod::UI.puts '【修复结果】dry-run，未执行'
            next
          end

          unless @assume_yes || action[:auto_confirm] || confirm_jenkins_fix_action?(action)
            Pod::UI.puts '【修复结果】已跳过'
            next
          end

          execute_jenkins_fix_action(action)
          if action[:stop_after_success]
            Pod::UI.puts "【修复结果】打包机 cocoapods-podx 已升级到 #{action[:target_version]}，请重新执行 podx publish。"
            break
          end
        end
      end

      def print_jenkins_failure_report(log, log_file, report)
        Pod::UI.puts "【Jenkins日志】#{log[:log_uri]}"
        Pod::UI.puts "【日志文件】#{log_file}"
        Pod::UI.puts "【失败分类】#{report[:type]}"
        Pod::UI.puts "【失败原因】#{report[:reason]}"
        report[:evidence].each { |line| Pod::UI.puts "【关键日志】#{line}" }
        report[:suggestions].each { |line| Pod::UI.puts "【修复建议】#{line}" }
      end

      def fetch_jenkins_build_log(build, line_limit: nil)
        failed = []
        urls = jenkins_build_urls(build)
        urls.each_with_index do |build_url, index|
          log_uri = URI.join(build_url, 'consoleText')
          request = Net::HTTP::Get.new(log_uri)
          apply_jenkins_auth(request)
          begin
            response = request_jenkins(log_uri, request)
            raise Pod::Informative, jenkins_http_error_message(response) unless response.is_a?(Net::HTTPSuccess)

            @selected_jenkins_job_url = jenkins_job_url_from_build_url(build_url)
            lines = safe_jenkins_text(response.body).lines.map { |line| strip_ansi(line).rstrip }
            lines = lines.last(line_limit.to_i) if line_limit.to_i.positive?
            return {
              build_url: build_url,
              log_uri: log_uri,
              lines: lines
            }
          rescue => e
            raise unless jenkins_connection_error?(e)

            failed << [build_url, e]
            next_url = urls[index + 1]
            Pod::UI.puts "【Jenkins日志】#{build_url} 不可用，切换备用：#{next_url}" if next_url
          end
        end

        failed_url, error = failed.last
        raise Pod::Informative, jenkins_connection_error_message(failed_url || jenkins_build_url(build), error)
      end

      def fetch_jenkins_build_history(limit)
        tree = 'builds[number,url,result,timestamp,duration,building,actions[parameters[name,value],causes[shortDescription,userId,userName]],changeSet[items[msg,commitId,author[fullName]]]]'
        failed = []
        urls = jenkins_job_urls_for_query
        urls.each_with_index do |job_url, index|
          uri = URI.join(job_url, "api/json?tree=#{tree}{0,#{limit}}")
          begin
            data = jenkins_json(uri)
            @selected_jenkins_job_url = job_url
            builds = data.fetch('builds', []).first(limit)
            return builds.map { |build| jenkins_history_row(build) }
          rescue => e
            raise unless jenkins_connection_error?(e)

            failed << [job_url, e]
            next_url = urls[index + 1]
            Pod::UI.puts "【Jenkins任务】#{job_url} 不可用，切换备用：#{next_url}" if next_url
          end
        end

        failed_url, error = failed.last
        raise Pod::Informative, jenkins_connection_error_message(failed_url || selected_jenkins_job_url, error)
      end

      def jenkins_history_row(build)
        params = jenkins_build_parameters(build)
        causes = jenkins_build_causes(build)
        change = jenkins_build_change(build)
        {
          number: "##{build['number'] || '-'}",
          branch: jenkins_history_branch(params),
          channel: jenkins_history_channel(params),
          source: jenkins_history_source(params, causes),
          result: jenkins_history_result(build),
          duration: format_jenkins_duration(build['duration']),
          commit: change[:commit].to_s.empty? ? '-' : short_commit(change[:commit]),
          log: change[:message]
        }
      end

      def jenkins_build_parameters(build)
        params = {}
        build.fetch('actions', []).compact.each do |action|
          action.fetch('parameters', []).each do |parameter|
            params[parameter['name'].to_s] = parameter['value'].to_s
          end
        end
        params
      end

      def jenkins_history_branch(params)
        branch = params['branch'] || params['BRANCH']
        value = branch.to_s.strip
        return '-' if value.empty?

        value.sub(%r{\Arefs/remotes/origin/}, '').sub(%r{\Aorigin/}, '')
      end

      def jenkins_build_causes(build)
        build.fetch('actions', []).compact.flat_map do |action|
          action.fetch('causes', []).map do |cause|
            {
              description: cause['shortDescription'].to_s,
              user_id: cause['userId'].to_s,
              user_name: cause['userName'].to_s
            }
          end
        end
      end

      def jenkins_build_change(build)
        item = build.dig('changeSet', 'items').to_a.first || {}
        {
          commit: item['commitId'].to_s,
          message: item['msg'].to_s.empty? ? '-' : item['msg'].to_s
        }
      end

      def jenkins_history_channel(params)
        value = params['DEPLOY_TARGET'] || params['deploy_target'] || params['target'] || params['TARGET']
        case value.to_s
        when /Pgyer/i
          '蒲公英'
        when /TestFlight/i
          'TestFlight'
        when /AppStore/i
          'AppStore'
        when ''
          '-'
        else
          value.to_s.sub(/,+\z/, '')
        end
      end

      def jenkins_history_source(params, causes)
        marker = params['PODX_TRIGGER_SOURCE'] || params['PODX_PUBLISH_SOURCE'] || params['PODX_SOURCE'] || params['BUILD_SOURCE']
        return 'podx publish' if marker.to_s.match?(/podx/i)
        return 'podx publish' if params['PODX_PUBLISH'].to_s == '1'

        text = causes.map { |cause| cause[:description] }.join(' ')
        return 'podx publish' if legacy_podx_publish_history?(params, causes)
        return 'Jenkins手动' if text.match?(/Started by user/i)
        return '上游任务' if text.match?(/Started by upstream project/i)
        return '定时触发' if text.match?(/Started by timer/i)
        return 'SCM触发' if text.match?(/Started by SCM/i)

        text.empty? ? '-' : truncate_display(text, 16)
      end

      def legacy_podx_publish_history?(params, causes)
        has_publish_params = (params['branch'] || params['BRANCH']) && params['DEPLOY_TARGET'] && params.key?('VERIFICATION_PASSWORD')
        anonymous_user = causes.any? do |cause|
          cause[:description].match?(/Started by user anonymous/i) || cause[:user_name].to_s == 'anonymous'
        end

        has_publish_params && anonymous_user
      end

      def jenkins_history_result(build)
        return 'BUILDING' if build['building']

        result = build['result'].to_s
        result.empty? ? 'UNKNOWN' : result
      end

      def print_jenkins_build_history_table(rows)
        if rows.empty?
          Pod::UI.puts '【最近构建】暂无记录'
          return
        end

        headers = %w[构建号 分支 渠道 来源 结果 耗时 Commit Commit信息]
        table_rows = rows.map do |row|
          [
            row[:number],
            truncate_display(row[:branch], 28),
            row[:channel],
            row[:source],
            row[:result],
            row[:duration],
            row[:commit],
            truncate_display(row[:log], 50)
          ]
        end
        widths = headers.each_with_index.map do |header, index|
          ([display_width(header)] + table_rows.map { |row| display_width(row[index]) }).max
        end
        separator = "+#{widths.map { |width| '-' * (width + 2) }.join('+')}+"

        Pod::UI.puts separator
        Pod::UI.puts "| #{format_publish_table_row(headers, widths)} |"
        Pod::UI.puts separator
        table_rows.each { |row| Pod::UI.puts "| #{format_publish_table_row(row, widths)} |" }
        Pod::UI.puts separator
      end

      def jenkins_history_limit
        raw = @jenkins_history_limit || @pod_names.first
        value = raw.to_s.strip
        return 10 if value.empty?

        limit = Integer(value)
        [[limit, 1].max, 50].min
      rescue ArgumentError
        raise Pod::Informative, "最近构建数量不合法：#{value}，请使用数字，例如：podx publish history 10"
      end

      def validate_jenkins_log_context!
        return if File.exist?(podfile_path)
        return if non_podfile_publish_job_configured?

        raise Pod::Informative, '非 Podfile 工程查看 Jenkins 日志时必须指定 job，例如：podx publish log --job nnrtc-ios-build'
      end

      def normalize_jenkins_log_build(build)
        value = build.to_s.strip
        return 'lastBuild' if value.empty?
        return value if value.start_with?('http://', 'https://')
        return value if value.match?(/\A(lastBuild|lastCompletedBuild|lastSuccessfulBuild|lastFailedBuild|lastUnsuccessfulBuild)\z/)
        return value if value.match?(/\A\d+\z/)

        raise Pod::Informative, "Jenkins 构建号不合法：#{value}，请使用数字、lastBuild 或构建 URL"
      end

      def jenkins_build_url(build)
        if build.start_with?('http://', 'https://')
          return normalize_jenkins_job_url(build)
        end

        URI.join(selected_jenkins_job_url, "#{build}/").to_s
      end

      def jenkins_build_urls(build)
        if build.start_with?('http://', 'https://')
          return [normalize_jenkins_job_url(build)]
        end

        jenkins_job_urls_for_query.map { |job_url| URI.join(job_url, "#{build}/").to_s }
      end

      def jenkins_job_url_from_build_url(build_url)
        normalized = normalize_jenkins_job_url(build_url.to_s)
        match = normalized.match(%r{\A(.*/job/[^/]+/)})
        match ? match[1] : selected_jenkins_job_url
      end

      def write_jenkins_log_file(build, lines)
        filename = "podx-jenkins-#{configured_jenkins_job_name}-#{build}-#{Time.now.strftime('%Y%m%d%H%M%S')}.log"
        filename = filename.gsub(%r{[^0-9A-Za-z._-]+}, '_')
        path = File.join(Dir.tmpdir, filename)
        File.write(path, "#{lines.join("\n")}\n")
        path
      end

      def open_jenkins_log_file(path)
        return unless RUBY_PLATFORM.include?('darwin')

        system('open', '-t', path) || system('open', path)
      rescue
        nil
      end

      def analyze_jenkins_failure(lines)
        normalized = lines.map { |line| line.to_s.strip }.reject(&:empty?)
        primary = jenkins_primary_failure_lines(normalized)
        evidence = primary.empty? ? normalized.select { |line| jenkins_failure_marker?(line) }.last(8) : primary
        text = normalized.join("\n")

        if text.match?(/Finished:\s*ABORTED|Aborted by|任务已取消|cancelled/i)
          return failure_report('打包任务取消', 'Jenkins 构建被取消或队列任务被取消。', evidence, [
            '确认是否人工取消或 Jenkins 节点重启。',
            '如果不是主动取消，重新执行 podx publish。'
          ])
        end

        if text.match?(/Invalid `Podfile` file|Podfile\.overlay\.config\.yml|podx\.config\.yml/i)
          return failure_report('CocoaPods 配置', first_reason(evidence, 'Podfile 或 podx 配置缺失/不兼容。'), evidence, [
            '优先检查打包机 cocoapods-podx 版本；如果版本过旧，请先在 Jenkins 打包机升级到最新版本。',
            '确认发布分支包含最新 Podfile、podx.config.yml 和 cocoapods-podx 接入代码。',
            '如果 Jenkins 仍使用旧 Podfile.overlay.config.yml，需要同步迁移配置或补齐兼容文件。',
            '升级后在打包机执行 podx version 和 podx doctor 验证环境，再重新发布。',
            '在本地执行 podx doctor 和 podx install 验证后再重新发布。'
          ])
        end

        if text.match?(/Unable to satisfy the following requirements|Unable to satisfy.*requirements/i)
          return failure_report('CocoaPods 版本约束', first_reason(evidence, 'Pod 版本约束无法满足。'), evidence, [
            '检查 Podfile、third_sdk.rb、Podfile.lock 和私有 spec 仓库中声明的版本约束是否一致。',
            '确认目标版本已经发布到私有 Specs/Nexus，并且 Jenkins 已更新 specs 仓库。',
            '如果是 Podfile.lock 锁住旧版本，优先在本地执行 podx update 对应 pod 验证后提交 Podfile.lock。'
          ])
        end

        if text.match?(/CocoaPods could not find|Unable to find a specification|Error installing|pod install|pod update/i)
          return failure_report('CocoaPods 依赖', first_reason(evidence, 'Pod 依赖解析或安装失败。'), evidence, [
            '检查私有 spec 源和目标 pod 版本是否存在。',
            '必要时执行 pod repo update 或 podx update 对齐本地组件。',
            '如果是网络下载失败，检查 Jenkins 到 Git/Specs 服务的连通性。'
          ])
        end

        if text.match?(/No space left on device|There is not enough disk space|磁盘空间不足|Disk.*full/i)
          return failure_report('磁盘空间', first_reason(evidence, 'Jenkins 节点磁盘空间不足。'), evidence, [
            '清理 DerivedData、Archives、临时目录和旧构建产物。',
            '检查 Jenkins 节点磁盘监控和自动清理策略。'
          ])
        end

        if text.match?(/xcodebuild: error: SDK|unable to find sdk|SDK .* cannot be located|toolchain|DEVELOPER_DIR|xcode-select|xcrun: error:.*metal|metal(?:lib)?: error|Metal Toolchain|MTLCompiler|metal compiler/i)
          return failure_report('Xcode/SDK 环境', first_reason(evidence, 'Jenkins Xcode、SDK 或 Toolchain 环境异常。'), evidence, [
            '检查 Jenkins 节点 Xcode 版本、DEVELOPER_DIR、xcode-select 和 SDK 是否存在。',
            '确认打包 job 使用的 Xcode 与项目/二进制库要求一致。',
            '如果升级 Xcode 后出现 Metal、metallib 或 xcrun metal 相关错误，优先确认 Jenkins 已切换到新 Xcode 的开发者工具链，并检查 Metal 工具链组件是否完整。'
          ])
        end

        if text.match?(/CFBundleShortVersionString|MinimumOSVersion|Invalid MinimumOSVersion|App Store Connect|altool|iTMSTransporter/i) &&
            text.match?(/\.framework|framework/i)
          return failure_report('App Store Framework 元数据', first_reason(evidence, '嵌入的 framework Info.plist 元数据不符合 App Store Connect 校验规则。'), evidence, [
            '检查报错 framework 的 Info.plist，确保 CFBundleShortVersionString 最多三段非负整数，例如 1.5.0。',
            '确保 CFBundleVersion 存在且为合法版本号，建议与 CFBundleShortVersionString 保持一致。',
            '确保 MinimumOSVersion 存在且为合法 iOS 最低系统版本，例如 13.0。',
            '如果是二进制 Pod，在对应 podspec 的 prepare_command 中统一补齐/规范化 framework Info.plist。',
            'libwebp.framework 常见修复：将 1.5.0.0 规范为 1.5.0，并补齐 MinimumOSVersion = 13.0；蒲公英可能不严格校验，但 TestFlight/App Store 会校验。'
          ])
        end

        if text.match?(/Failed to connect|Could not resolve host|Connection timed out|Operation timed out|git\.leigod\.top|github\.com/i)
          return failure_report('网络或 Git 服务', first_reason(evidence, 'Jenkins 无法访问 Git、Specs 或第三方下载源。'), evidence, [
            '检查 Jenkins 节点网络、DNS、代理和 Git 服务可用性。',
            '如果依赖来自 GitHub，优先切到内部镜像或内部二进制依赖。'
          ])
        end

        if text.match?(/Undefined symbols|Framework .* not found|Library not loaded|Unable to resolve module dependency|module .* was built with|this SDK is not supported by the compiler/i)
          return failure_report('编译/链接/二进制兼容', first_reason(evidence, '编译、链接或二进制 Swift 版本兼容失败。'), evidence, [
            '确认二进制库构建 Swift/Xcode 版本与 Jenkins Xcode 版本一致。',
            '检查 podspec 的 vendored_frameworks、dependencies、frameworks 和 static/dynamic 配置。',
            '必要时重新打包二进制库并更新 pod 版本。'
          ])
        end

        if text.match?(/Code ?Sign|Provisioning profile|No profiles for|certificate|Signing for/i)
          return failure_report('签名/证书', first_reason(evidence, '证书、描述文件或签名配置失败。'), evidence, [
            '检查 Jenkins 证书、描述文件、bundle id、team id 和 exportOptions 配置。',
            '确认目标发布渠道对应的签名资产未过期。'
          ])
        end

        if text.match?(/Command PhaseScriptExecution failed|Run custom shell script|SwiftLint|rswift|R.swift|脚本执行失败/i)
          return failure_report('构建脚本', first_reason(evidence, 'Jenkins 构建脚本或生成脚本执行失败。'), evidence, [
            '检查脚本依赖工具是否安装、PATH 是否正确、脚本是否有执行权限。',
            '如果是 SwiftLint/R.swift 等工具版本问题，优先同步打包机工具链。'
          ])
        end

        if text.match?(/fatal error: .* file not found|'.*\.h' file not found|No such file or directory/i)
          return failure_report('文件或头文件缺失', first_reason(evidence, '构建缺少头文件、资源或生成文件。'), evidence, [
            '检查 podspec 的 source_files、public_header_files、resources 配置。',
            '确认缺失文件已提交到远端发布分支。'
          ])
        end

        failure_report('未知失败', first_reason(evidence, '未匹配到明确失败类型，请查看日志文件。'), evidence, [
          '打开日志文件查看第一处 error / failed / exception。',
          '必要时执行 podx publish doctor BUILD --lines 200 聚焦最后日志。'
        ])
      end

      def failure_report(type, reason, evidence, suggestions)
        {
          type: type,
          reason: reason,
          evidence: evidence.first(8),
          suggestions: suggestions
        }
      end

      def first_reason(evidence, fallback)
        evidence.find { |line| !line.to_s.strip.empty? } || fallback
      end

      def jenkins_failure_marker?(line)
        line.match?(/error:|ERROR|FAIL|FAILED|Exception|Invalid `Podfile` file|CocoaPods could not find|Unable to find a specification|Error installing|Code ?Sign|Provisioning profile|Undefined symbols|Framework .* not found|Library not loaded|file not found|CFBundleShortVersionString|MinimumOSVersion|App Store Connect|iTMSTransporter|altool/i)
      end

      def jenkins_fix_actions(report)
        case report[:type]
        when 'CocoaPods 配置'
          root = jenkins_project_directory
          actions = []
          if jenkins_fix_job_name
            actions << {
              key: :jenkins_upgrade_podx,
              title: "触发 Jenkins 维护 job 升级打包机 cocoapods-podx 到 #{cocoapods_podx_version}：#{jenkins_fix_job_name}",
              remote_job: jenkins_fix_job_name,
              target_version: cocoapods_podx_version,
              auto_confirm: true,
              stop_after_success: true
            }
          end
          actions + [
            {
              key: :upgrade_podx,
              title: '升级当前机器 cocoapods-podx。若失败发生在 Jenkins，这条命令需要在 Jenkins 打包机执行才生效。',
              chdir: root,
              command: ['/bin/sh', File.join(root, 'tools', 'cocoapods-podx.sh'), 'install']
            },
            {
              key: :podx_doctor,
              title: '检查当前工程 podx 接入和配置状态。',
              chdir: root,
              command: ['podx', 'doctor']
            }
          ]
        when 'CocoaPods 依赖', 'CocoaPods 版本约束'
          root = jenkins_project_directory
          [
            {
              key: :pod_repo_update,
              title: '更新 CocoaPods specs 仓库。',
              chdir: root,
              command: ['podx', 'repo', 'update']
            }
          ]
        else
          []
        end
      end

      def confirm_jenkins_fix_action?(action)
        return false unless $stdin.tty?

        $stdout.print("是否执行修复动作「#{action[:title]}」？[y/N] ")
        $stdout.flush
        answer = $stdin.gets.to_s.strip.downcase
        answer == 'y' || answer == 'yes'
      end

      def execute_jenkins_fix_action(action)
        return execute_remote_jenkins_fix_action(action) if action[:remote_job]

        command = action[:command]
        chdir = action[:chdir] || jenkins_project_directory
        output, status = Open3.capture2e(*command, chdir: chdir)
        safe_jenkins_text(output).lines.map(&:rstrip).reject(&:empty?).last(20).each do |line|
          Pod::UI.puts "【修复日志】#{line}"
        end

        if status.success?
          Pod::UI.puts "【修复结果】成功 #{action[:key]}"
        else
          Pod::UI.puts "【修复结果】失败 #{action[:key]}"
          raise Pod::Informative, "修复动作失败：#{action[:title]}"
        end
      end

      def jenkins_project_directory
        respond_to?(:project_directory) ? project_directory : @project_directory
      end

      def jenkins_fix_job_name
        value = @jenkins_fix_job || ENV['COCOAPODS_PODX_JENKINS_FIX_JOB']
        value && !value.to_s.strip.empty? ? value.to_s.strip : nil
      end

      def cocoapods_podx_version
        Gem.loaded_specs['cocoapods-podx']&.version&.to_s ||
          Gem::Specification.find_all_by_name('cocoapods-podx').max_by(&:version)&.version&.to_s ||
          'unknown'
      end

      def execute_remote_jenkins_fix_action(action)
        last_error = nil
        jenkins_fix_job_urls(action[:remote_job]).each do |job_url|
          trigger_jenkins_fix_job_with_url(job_url)
          Pod::UI.puts "【修复结果】成功 #{action[:key]}"
          return
        rescue JenkinsConnectionError => e
          last_error = e
          Pod::UI.puts "【修复日志】Jenkins 修复 job 地址不可用，切换备用：#{job_url} #{e.message}"
        end

        raise Pod::Informative, "Jenkins 修复 job 触发失败：#{last_error&.message || '所有地址均不可用'}"
      end

      def jenkins_fix_job_urls(job)
        job.to_s.start_with?('http://', 'https://') ? [normalize_jenkins_job_url(job)] : default_jenkins_job_urls(job)
      end

      def trigger_jenkins_fix_job_with_url(job_url)
        response, uri = trigger_jenkins_fix_job_request(job_url, 'build')
        if response.is_a?(Net::HTTPBadRequest)
          response, uri = trigger_jenkins_fix_job_request(job_url, 'buildWithParameters', form_data: {})
        end

        unless response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPRedirection)
          raise Pod::Informative, jenkins_http_error_message(response)
        end

        queue_url = response['Location'].to_s
        Pod::UI.puts "【修复日志】Jenkins #{job_url}"
        Pod::UI.puts "【修复日志】触发接口 #{uri}"
        Pod::UI.puts "【修复日志】队列 #{queue_url}" unless queue_url.empty?
        wait_for_jenkins_result(job_url, queue_url, '打包机修复') unless queue_url.empty?
      rescue => e
        raise unless jenkins_connection_error?(e)

        raise JenkinsConnectionError, e.message
      end

      def trigger_jenkins_fix_job_request(job_url, endpoint, form_data: nil)
        uri = URI.join(job_url, endpoint)
        request = Net::HTTP::Post.new(uri)
        request.set_form_data(form_data) if form_data
        apply_jenkins_auth(request)
        apply_jenkins_crumb(request, uri)

        response = request_jenkins(uri, request)
        [response, uri]
      end

      def run_hermes_failure_analysis(log_file, report)
        hermes = hermes_command
        unless hermes
          Pod::UI.puts '【Hermes分析】未检测到 hermes，已使用本地规则完成诊断'
          return
        end

        prompt = hermes_failure_prompt(log_file, report)
        output, status = Timeout.timeout(hermes_analysis_timeout) do
          Open3.capture2e(hermes, '-z', prompt)
        end

        if status.success? && !output.to_s.strip.empty?
          Pod::UI.puts '【Hermes分析】'
          safe_jenkins_text(output).lines.map(&:rstrip).reject(&:empty?).each { |line| Pod::UI.puts line }
        else
          Pod::UI.puts "【Hermes分析】执行失败：#{safe_jenkins_text(output).lines.first.to_s.strip}"
        end
      rescue Timeout::Error
        Pod::UI.puts "【Hermes分析】超时，已跳过，日志文件：#{log_file}"
      rescue => e
        Pod::UI.puts "【Hermes分析】执行失败：#{e.message}"
      end

      def hermes_command
        configured = ENV['COCOAPODS_PODX_HERMES_BIN'] || ENV['HERMES_BIN']
        return File.expand_path(configured) if configured && File.executable?(File.expand_path(configured))

        user_bin = File.expand_path('~/.local/bin/hermes')
        return user_bin if File.executable?(user_bin)

        stdout, status = Open3.capture2('which', 'hermes', err: File::NULL)
        status.success? ? stdout.strip : nil
      end

      def hermes_failure_prompt(log_file, report)
        <<~PROMPT
          你是 iOS DevOps 打包失败诊断助手。请基于下面的本地规则诊断和 Jenkins 日志文件，输出简短中文结论。
          不要修改文件，不要执行命令，只输出：
          1. 失败类型
          2. 根因判断
          3. 建议修复步骤
          4. 是否适合自动修复

          日志文件：#{log_file}
          本地规则分类：#{report[:type]}
          本地规则原因：#{report[:reason]}
          关键日志：
          #{report[:evidence].join("\n")}
        PROMPT
      end

      def hermes_analysis_timeout
        ENV.fetch('COCOAPODS_PODX_HERMES_TIMEOUT', '120').to_i
      end

      def validate_jenkins_publish_context!
        return if File.exist?(podfile_path)

        return if non_podfile_publish_job_configured?

        raise Pod::Informative, '非 Podfile 工程执行 podx publish 时必须指定 Jenkins job，例如：podx publish --job nnrtc-ios-build'
      end

      def non_podfile_publish_job_configured?
        return true if @jenkins_job && !@jenkins_job.strip.empty?
        return true if @jenkins_url && !@jenkins_url.strip.empty?

        ENV['COCOAPODS_PODX_JENKINS_URL'] || ENV['COCOAPODS_OVERLAY_JENKINS_URL']
      end

      def jenkins_deploy_target(channel)
        normalized = channel.to_s.strip.downcase
        if jenkins_placeholder_argument?(normalized)
          raise Pod::Informative, "发布渠道不能使用示例占位符：#{channel}，支持 pgyer/tf/app/framework"
        end

        case normalized
        when 'pgyer', 'pgy', '蒲公英'
          { kind: :app, name: '蒲公英', value: 'Pgyer,' }
        when 'testflight', 'tf'
          { kind: :app, name: 'TestFlight', value: 'TestFlight,' }
        when 'appstore', 'app-store', 'store', 'app', '苹果商店'
          { kind: :app, name: '苹果商店', value: 'AppStore,' }
        when 'framework', 'fw', '打framework', '打框架'
          { kind: :framework, name: '打 Framework', value: nil }
        else
          raise Pod::Informative, "未知发布渠道：#{channel}，支持 pgyer/pgy、tf/testflight、app/appstore、framework/fw"
        end
      end

      def validate_jenkins_publish_target!(job_profile, target)
        return if job_profile[:kind] == target[:kind]

        if job_profile[:kind] == :framework
          raise Pod::Informative, "Jenkins job #{job_profile[:job_name]} 仅支持打 Framework，不支持 #{target[:name]}。"
        end

        raise Pod::Informative, "Jenkins job #{job_profile[:job_name]} 支持 pgyer/tf/app，不支持 #{target[:name]}。"
      end

      def jenkins_build_params(job_profile, branch, target)
        params = { job_profile[:branch_param] => branch }
        if target[:kind] == :app
          params['DEPLOY_TARGET'] = target[:value]
          params['VERIFICATION_PASSWORD'] = jenkins_publish_password_for(target)
        end
        apply_jenkins_podx_source_param!(params, job_profile)
        params
      end

      def jenkins_publish_job_profile
        @jenkins_publish_job_profile ||= begin
          definitions = jenkins_parameter_definitions
          parameter_names = definitions.map { |definition| definition['name'].to_s }
          job_name = configured_jenkins_job_name

          if parameter_names.include?('DEPLOY_TARGET')
            {
              kind: :app,
              job_name: job_name,
              default_channel: 'pgyer',
              branch_param: parameter_names.include?('branch') ? 'branch' : 'BRANCH',
              source_param: jenkins_podx_source_param_name(parameter_names)
            }
          elsif parameter_names.include?('BRANCH') || framework_job_name?(job_name)
            {
              kind: :framework,
              job_name: job_name,
              default_channel: 'framework',
              branch_param: 'BRANCH',
              source_param: jenkins_podx_source_param_name(parameter_names)
            }
          else
            default_jenkins_publish_job_profile(job_name)
          end
        end
      end

      def default_jenkins_publish_job_profile(job_name)
        return {
          kind: :framework,
          job_name: job_name,
          default_channel: 'framework',
          branch_param: 'BRANCH',
          source_param: nil
        } if framework_job_name?(job_name)

        {
          kind: :app,
          job_name: job_name,
          default_channel: 'pgyer',
          branch_param: 'branch',
          source_param: nil
        }
      end

      def jenkins_podx_source_param_name(parameter_names)
        %w[PODX_TRIGGER_SOURCE PODX_PUBLISH_SOURCE PODX_SOURCE BUILD_SOURCE PODX_PUBLISH].find do |name|
          parameter_names.include?(name)
        end
      end

      def apply_jenkins_podx_source_param!(params, job_profile)
        source_param = job_profile[:source_param].to_s
        return if source_param.empty?

        params[source_param] = source_param == 'PODX_PUBLISH' ? '1' : 'podx publish'
      end

      def framework_job_name?(job_name)
        job_name.to_s.include?('framework') || job_name.to_s.include?('rtc')
      end

      def configured_jenkins_job_name
        return @jenkins_job.to_s.strip if @jenkins_job && !@jenkins_job.strip.empty? && !@jenkins_job.start_with?('http://', 'https://')

        raw_url = @jenkins_url
        raw_url ||= @jenkins_job if @jenkins_job && @jenkins_job.start_with?('http://', 'https://')
        raw_url ||= ENV['COCOAPODS_PODX_JENKINS_URL'] || ENV['COCOAPODS_OVERLAY_JENKINS_URL']
        if raw_url
          match = raw_url.match(%r{/job/([^/]+)/?})
          return match[1] if match
        end

        'nn'
      end

      def jenkins_parameter_definitions
        data = jenkins_json(URI.join(selected_jenkins_job_url, 'api/json?depth=1'))
        data.fetch('property', []).flat_map do |property|
          property.fetch('parameterDefinitions', [])
        end
      rescue
        []
      end

      def jenkins_publish_branch
        branch = @publish_branch || main_app_branch
        raise Pod::Informative, '无法获取当前 git 分支，请使用 --publish-branch=origin/xxx 指定。' if branch.nil? || branch.empty?
        if jenkins_placeholder_argument?(branch)
          raise Pod::Informative, "发布分支不能使用示例占位符：#{branch}，请使用真实分支，例如：podx publish --branch release/5.14.2"
        end

        branch.start_with?('origin/') ? branch : "origin/#{branch}"
      end

      def validate_jenkins_publish_branch!(branch, target)
        if jenkins_placeholder_argument?(branch.to_s.sub(%r{\Aorigin/}, ''))
          raise Pod::Informative, "发布分支不能使用示例占位符：#{branch}，请使用真实分支，例如：podx publish --branch release/5.14.2"
        end
        return if target[:kind] == :framework
        return if target[:value] == 'Pgyer,'

        normalized_branch = branch.to_s.sub(%r{\Aorigin/}, '')
        return if normalized_branch.match?(/\Arelease\/\d+\.\d+\.\d+\z/)

        unless jenkins_publish_branch_explicit?
          command = target[:value] == 'AppStore,' ? 'podx publish app' : 'podx publish tf'
          raise Pod::Informative, "#{target[:name]} 当前分支不是 release/x.x.x，不能直接执行 #{command}；请使用 \"#{command} --branch release/x.x.x\"，或者切换到 \"release/x.x.x\" 分支后执行。当前分支为 #{branch}"
        end

        raise Pod::Informative, "#{target[:name]} 只能发布 release/x.x.x 分支，当前分支为 #{branch}"
      end

      def jenkins_placeholder_argument?(value)
        text = value.to_s.strip
        return false if text.empty?
        return true if text.match?(/\A\[.+\]\z/)
        return true if %w[BRANCH VERSION BUILD NAME N].include?(text)
        return true if text.match?(%r{\Arelease/[xyz](?:\.[xyz])+\z}i)

        false
      end

      def validate_publish_remote_release_branches!(branch, rows, target)
        return if target[:kind] == :framework
        return if target[:value] == 'Pgyer,'

        normalized_branch = branch.to_s.sub(%r{\Aorigin/}, '')
        return unless normalized_branch.match?(/\Arelease\/\d+\.\d+\.\d+\z/)

        missing_rows = rows.select { |row| row[:commit].to_s == '-' }
        return if missing_rows.empty?

        details = missing_rows.map do |row|
          "#{row[:repo]} #{row[:branch]}（#{row[:log]}）"
        end
        raise Pod::Informative, "#{target[:name]} 发布要求 release/x.x.x 分支在远端主工程和依赖组件仓库都存在，未检测到：#{details.join('；')}"
      end

      def jenkins_publish_branch_explicit?
        !@publish_branch.to_s.strip.empty?
      end

      def jenkins_publish_password_for(target)
        return ',' if target[:value] == 'Pgyer,'
        return '***,' if @dry_run

        password = @publish_password.nil? ? prompt_jenkins_publish_password(target) : @publish_password
        password = password.to_s.sub(/,+\z/, '')
        validate_jenkins_publish_password!(target, password)
        "#{password},"
      end

      def prompt_jenkins_publish_password(target)
        prompt = "请输入发布#{target[:name]}打包密码："
        password = if $stdin.tty?
          $stdout.print(prompt)
          $stdout.flush
          begin
            system('stty', '-echo')
            value = $stdin.gets.to_s.chomp
            $stdout.puts
            value
          ensure
            system('stty', 'echo')
          end
        else
          Pod::UI.puts prompt
          $stdin.gets.to_s.chomp
        end

        raise Pod::Informative, "#{target[:name]} 打包密码不能为空" if password.strip.empty?

        password
      end

      def validate_jenkins_publish_password!(target, password)
        password = password.to_s.strip
        raise Pod::Informative, "#{target[:name]} 打包密码不能为空" if password.empty?

        expected = expected_jenkins_publish_password
        return if expected.nil? || expected.empty?
        return if password == expected

        raise Pod::Informative, "#{target[:name]} 打包密码错误，已取消发布。"
      end

      def expected_jenkins_publish_password
        ENV['COCOAPODS_PODX_JENKINS_PUBLISH_PASSWORD'] ||
          ENV['COCOAPODS_PODX_VERIFICATION_PASSWORD'] ||
          ENV['COCOAPODS_OVERLAY_PUBLISH_PASSWORD'] ||
          ENV['COCOAPODS_PODX_PUBLISH_PASSWORD'] ||
          '1234'
      end

      def print_publish_header(jenkins_branch, target)
        service_url = select_jenkins_job_url(verbose: true)
        Pod::UI.puts "【打包服务】#{service_url}"
        Pod::UI.puts "【打包分支】#{jenkins_branch}"
        Pod::UI.puts '【打包来源】远端分支 HEAD，不包含本地未提交代码'
        Pod::UI.puts "【发布渠道】#{target[:name]}"
      end

      def git_repository_name
        git_repository_name_for(project_directory)
      end

      def git_repository_name_for(path)
        stdout, status = Open3.capture2('git', '-C', path, 'rev-parse', '--show-toplevel', err: File::NULL)
        return File.basename(path) unless status.success?

        File.basename(stdout.strip)
      end

      def git_commit_hash(path = project_directory)
        stdout, status = Open3.capture2('git', '-C', path, 'rev-parse', 'HEAD')
        status.success? ? stdout.strip : 'unknown'
      end

      def git_commit_log(path = project_directory)
        stdout, status = Open3.capture2('git', '-C', path, 'log', '-1', '--pretty=%s')
        status.success? ? stdout.strip : 'unknown'
      end

      def publish_git_rows(jenkins_branch)
        items = publish_remote_repo_items(jenkins_branch)
        rows = []
        print_remote_repo_progress(0, items.length, '远端仓库版本', '', '准备中')

        items.each_with_index do |item, index|
          current = index + 1
          print_remote_repo_progress(current, items.length, item[:repo], item[:branch], '查询中')
          info = begin
            remote_git_commit_info(item[:repo], item[:url], item[:branch])
          rescue => e
            {
              commit: '-',
              log: "远端信息获取失败：#{e.message}"
            }
          end
          rows << {
            repo: item[:repo],
            branch: item[:branch],
            commit: info[:commit],
            log: info[:log]
          }
          status = info[:commit] == '-' ? '失败' : short_commit(info[:commit])
          print_remote_repo_progress(current, items.length, item[:repo], item[:branch], status, done: current == items.length)
        end

        finish_remote_repo_progress

        rows
      end

      def publish_remote_repo_items(jenkins_branch)
        main_branch = jenkins_branch.sub(%r{\Aorigin/}, '')
        items = [
          {
            repo: git_repository_name,
            branch: main_branch,
            url: main_remote_url
          }
        ]

        return items unless File.exist?(podfile_path)

        publish_private_repo_names.each do |name|
          items << {
            repo: name,
            branch: main_branch,
            url: CocoapodsPodx::Runtime.remote_repo_url_for(name)
          }
        rescue => e
          items << {
            repo: name,
            branch: main_branch,
            url: nil,
            error: e.message
          }
        end

        items
      end

      def publish_main_remote_git_row(jenkins_branch)
        branch = jenkins_branch.sub(%r{\Aorigin/}, '')
        url = main_remote_url
        info = remote_git_commit_info(git_repository_name, url, branch)
        {
          repo: git_repository_name,
          branch: branch,
          commit: info[:commit],
          log: info[:log]
        }
      end

      def publish_private_remote_git_row(name)
        branch = declared_branch_for(name) || main_app_branch || 'unknown'
        url = CocoapodsPodx::Runtime.remote_repo_url_for(name)
        info = remote_git_commit_info(name, url, branch)
        {
          repo: name,
          branch: branch,
          commit: info[:commit],
          log: info[:log]
        }
      rescue => e
        {
          repo: name,
          branch: branch || 'unknown',
          commit: '-',
          log: "远端信息获取失败：#{e.message}"
        }
      end

      def publish_private_repo_names
        %w[
          NNBussCom
          NNApperance
          NNLibrary
          NNGeneral
          NNCategory
          NNLogModule
          NNNetWork
          NNRealReachability
          NNBasciCommon
          NNIMManager
        ]
      end

      def publish_git_row(name, path)
        unless File.directory?(path)
          return {
            repo: name,
            branch: 'missing',
            commit: '-',
            log: "本地仓库不存在：#{path}"
          }
        end

        unless git_work_tree?(path)
          return {
            repo: name,
            branch: 'not-git',
            commit: '-',
            log: "目录不是 git 仓库：#{path}"
          }
        end

        {
          repo: name,
          branch: git_branch_for(path) || 'detached',
          commit: git_commit_hash(path),
          log: git_commit_log(path)
        }
      end

      def main_remote_url
        stdout, status = Open3.capture2('git', '-C', project_directory, 'remote', 'get-url', 'origin', err: File::NULL)
        return nil unless status.success?

        stdout.strip
      end

      def remote_git_commit_info(repo_name, remote_url, branch)
        raise '远端仓库地址为空' if remote_url.to_s.strip.empty?
        raise '远端分支为空' if branch.to_s.strip.empty? || branch == 'unknown'

        Dir.mktmpdir('cocoapods-podx-remote-git-') do |dir|
          run_git_in_tmp!(dir, 'init', '-q')
          run_git_in_tmp!(dir, 'fetch', '--depth=1', remote_url, branch)
          commit, commit_status = Open3.capture2('git', '-C', dir, 'rev-parse', 'FETCH_HEAD')
          log, log_status = Open3.capture2('git', '-C', dir, 'log', '-1', '--pretty=%s', 'FETCH_HEAD')
          unless commit_status.success? && log_status.success?
            return {
              commit: '-',
              log: "远端分支不存在或无法获取：#{branch}"
            }
          end

          {
            commit: commit.strip,
            log: log.strip
          }
        end
      rescue => e
        {
          commit: '-',
          log: "远端分支不存在或无法获取：#{branch}，#{e.message}"
        }
      end

      def run_git_in_tmp!(dir, *args)
        Timeout.timeout(remote_git_timeout) do
          stdout, status = Open3.capture2e('git', '-C', dir, *args)
          raise stdout.strip unless status.success?

          stdout
        end
      end

      def remote_git_timeout
        ENV.fetch('COCOAPODS_PODX_REMOTE_GIT_TIMEOUT', ENV.fetch('COCOAPODS_OVERLAY_REMOTE_GIT_TIMEOUT', '30')).to_i
      end

      def print_remote_repo_progress(current, total, repo_name, branch, status, done: false)
        detail = [repo_name, branch, status].reject { |value| value.to_s.empty? }.join(' ')
        line = "【打包准备】#{progress_bar(current, total)} #{current}/#{total} #{detail}"
        if $stdout.tty?
          $stdout.print("\r#{line}")
          $stdout.flush
        end
      end

      def finish_remote_repo_progress
        line = '【打包准备】完成'
        if $stdout.tty?
          $stdout.print("\r#{line}#{' ' * 80}\n")
          $stdout.flush
        else
          Pod::UI.puts line
        end
      end

      def print_publish_prepare_progress(message)
        line = "【打包准备】#{truncate_display(message, 100)}"
        if $stdout.tty?
          $stdout.print("\r#{line}#{' ' * 20}")
          $stdout.flush
        else
          @last_publish_prepare_progress = line
        end
      end

      def finish_publish_prepare_progress(message = nil)
        line = message ? "【打包准备】#{truncate_display(message, 100)}" : @last_publish_prepare_progress
        return if line.to_s.empty?

        if $stdout.tty?
          $stdout.print("\r#{line}#{' ' * 80}\n")
          $stdout.flush
        else
          Pod::UI.puts line
        end
        @last_publish_prepare_progress = nil
      end

      def progress_bar(current, total)
        width = 20
        filled = total.to_i <= 0 ? 0 : (current.to_f / total * width).round
        filled = [[filled, 0].max, width].min
        "[#{'=' * filled}#{'-' * (width - filled)}]"
      end

      def print_publish_git_table(rows)
        headers = ['仓库', '分支', 'Commit', 'Commit信息']
        table_rows = rows.map { |row| [row[:repo], row[:branch], short_commit(row[:commit]), truncate_display(row[:log], 50)] }
        widths = headers.each_with_index.map do |header, index|
          ([header] + table_rows.map { |row| row[index].to_s }).map { |value| display_width(value) }.max
        end

        separator = "+-#{widths.map { |width| '-' * width }.join('-+-')}-+"
        Pod::UI.puts '【打包仓库】：'
        Pod::UI.puts separator
        Pod::UI.puts "| #{format_publish_table_row(headers, widths)} |"
        Pod::UI.puts separator
        table_rows.each do |row|
          Pod::UI.puts "| #{format_publish_table_row(row, widths)} |"
        end
        Pod::UI.puts separator
      end

      def format_publish_table_row(values, widths)
        values.each_with_index.map { |value, index| pad_display(value, widths[index]) }.join(' | ')
      end

      def short_commit(commit)
        value = commit.to_s
        return value if value == '-' || value.length <= 6

        value[0, 6]
      end

      def display_width(value)
        value.to_s.each_char.sum { |char| display_char_width(char) }
      end

      def display_char_width(char)
        code = char.ord
        return 0 if code.zero?
        return 0 if (0x0300..0x036F).cover?(code)
        return 0 if (0x1AB0..0x1AFF).cover?(code)
        return 0 if (0x1DC0..0x1DFF).cover?(code)
        return 0 if (0x20D0..0x20FF).cover?(code)
        return 0 if (0xFE00..0xFE0F).cover?(code)
        return 0 if (0xFE20..0xFE2F).cover?(code)
        return 2 if wide_display_char?(code)

        1
      end

      def wide_display_char?(code)
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

      def truncate_display(value, max_width)
        text = value.to_s
        return text if display_width(text) <= max_width

        suffix = '...'
        target_width = max_width - display_width(suffix)
        width = 0
        result = +''
        text.each_char do |char|
          char_width = display_char_width(char)
          break if width + char_width > target_width

          result << char
          width += char_width
        end
        result + suffix
      end

      def pad_display(value, width)
        text = value.to_s
        text + (' ' * [width - display_width(text), 0].max)
      end

      def jenkins_job_url
        jenkins_job_urls.first
      end

      def publish_jenkins_display_url
        selected_jenkins_job_url
      end

      def selected_jenkins_job_url
        @selected_jenkins_job_url ||= select_jenkins_job_url
      end

      def select_jenkins_job_url(verbose: false)
        return @selected_jenkins_job_url if @selected_jenkins_job_url

        urls = jenkins_job_urls
        urls.each do |job_url|
          print_publish_prepare_progress("探测 Jenkins #{job_url}") if verbose
          if jenkins_job_available?(job_url)
            @selected_jenkins_job_url = job_url
            finish_publish_prepare_progress("Jenkins 可用 #{job_url}") if verbose
            return job_url
          end
          print_publish_prepare_progress("Jenkins 不可用 #{job_url}") if verbose
        end

        finish_publish_prepare_progress("Jenkins 不可用，使用默认 #{urls.first}") if verbose
        @selected_jenkins_job_url = urls.first
      end

      def jenkins_job_available?(job_url)
        uri = URI.join(job_url, 'api/json?tree=buildable')
        request = Net::HTTP::Get.new(uri)
        apply_jenkins_auth(request)
        response = request_jenkins(uri, request, open_timeout: jenkins_probe_timeout, read_timeout: jenkins_probe_timeout)
        response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPRedirection)
      rescue
        false
      end

      def jenkins_job_urls
        if @jenkins_url
          return jenkins_job_urls_from_configured_url(@jenkins_url)
        end

        if @jenkins_job && !@jenkins_job.strip.empty?
          return jenkins_job_urls_from_configured_url(@jenkins_job) if @jenkins_job.start_with?('http://', 'https://')

          return default_jenkins_job_urls(@jenkins_job)
        end

        jenkins_url = ENV['COCOAPODS_PODX_JENKINS_URL'] || ENV['COCOAPODS_OVERLAY_JENKINS_URL']
        if jenkins_url
          return jenkins_job_urls_from_configured_url(jenkins_url)
        end

        default_jenkins_job_urls('nn')
      end

      def jenkins_job_urls_for_query
        selected = if instance_variable_defined?(:@selected_jenkins_job_url)
          @selected_jenkins_job_url
        elsif method(:selected_jenkins_job_url).owner != CocoapodsPodx::Commands::JenkinsPublish
          selected_jenkins_job_url
        end
        urls = jenkins_job_urls
        return urls unless selected

        [selected] + urls.reject { |url| url == selected }
      end

      def jenkins_job_urls_from_configured_url(raw_url)
        normalized = normalize_jenkins_job_url(raw_url.to_s.strip)
        uri = URI(normalized)
        match = normalized.match(%r{/job/([^/]+)/?})
        if match && default_jenkins_host?(uri.host)
          urls = default_jenkins_job_urls(match[1])
          return [normalized] + urls.reject { |url| url == normalized }
        end

        [normalized]
      rescue URI::InvalidURIError
        [normalize_jenkins_job_url(raw_url.to_s)]
      end

      def default_jenkins_host?(host)
        %w[10.1.3.177 10.1.107.211].include?(host.to_s)
      end

      def default_jenkins_job_urls(job_name)
        normalized_job = job_name.to_s.strip
        if normalized_job.start_with?('http://', 'https://')
          return [normalize_jenkins_job_url(normalized_job)]
        end

        [
          normalize_jenkins_job_url("http://10.1.3.177:8080/job/#{normalized_job}/"),
          normalize_jenkins_job_url("http://10.1.107.211:8080/job/#{normalized_job}/")
        ]
      end

      def normalize_jenkins_job_url(raw_url)
        raw_url.end_with?('/') ? raw_url : "#{raw_url}/"
      end

      def trigger_jenkins_build(params, target_name)
        failed_urls = []

        urls = jenkins_job_urls_for_trigger
        urls.each_with_index do |job_url, index|
          return if trigger_jenkins_build_with_url(job_url, params, target_name)
        rescue JenkinsConnectionError
          failed_urls << job_url
          next_url = urls[index + 1]
          if next_url
            print_jenkins_progress("Jenkins 地址不可用：#{job_url}，切换备用：#{next_url}")
          else
            print_jenkins_progress("Jenkins 地址不可用：#{job_url}")
          end
        end

        raise Pod::Informative, "Jenkins 发布触发失败：所有 Jenkins 地址均不可用（#{failed_urls.join('、')}）"
      end

      def jenkins_job_urls_for_trigger
        selected = @selected_jenkins_job_url
        urls = jenkins_job_urls
        return urls unless selected

        [selected] + urls.reject { |url| url == selected }
      end

      def trigger_jenkins_build_with_auto_fix_retry(params, target_name)
        attempts = 0

        begin
          trigger_jenkins_build(params, target_name)
        rescue JenkinsAutoFixApplied
          attempts += 1
          if attempts <= jenkins_auto_fix_retry_limit
            Pod::UI.puts "【自动修复】修复完成，自动重新触发 Jenkins 打包（#{attempts}/#{jenkins_auto_fix_retry_limit}）"
            print_jenkins_progress('等待 Jenkins 打包...')
            retry
          end

          raise Pod::Informative, "Jenkins #{target_name} 自动修复已执行，但已达到自动重试上限，请重新执行 podx publish。"
        end
      end

      def trigger_jenkins_build_with_url(job_url, params, target_name)
        uri = URI.join(job_url, 'buildWithParameters')
        request = Net::HTTP::Post.new(uri)
        request.set_form_data(params)
        apply_jenkins_auth(request)
        apply_jenkins_crumb(request, uri)

        response = request_jenkins(uri, request)
        unless response.is_a?(Net::HTTPSuccess) || response.is_a?(Net::HTTPRedirection)
          raise Pod::Informative, jenkins_http_error_message(response)
        end

        queue_url = response['Location'].to_s
        print_jenkins_progress("已触发 #{target_name} #{params['branch'] || params['BRANCH']} #{job_url}")
        print_jenkins_progress("队列 #{queue_url}") unless queue_url.empty?
        wait_for_jenkins_result(job_url, queue_url, target_name) unless queue_url.empty?
        true
      rescue => e
        raise unless jenkins_connection_error?(e)

        raise JenkinsConnectionError, e.message
      end

      def wait_for_jenkins_result(job_url, queue_url, target_name)
        queue_uri = resolve_jenkins_url(queue_url, job_url)
        build = wait_for_jenkins_executable(queue_uri, target_name)
        return if build.nil?

        build_url = build['url'].to_s
        build_url = resolve_jenkins_url(build_url, job_url).to_s
        build_number = build['number']
        print_jenkins_progress("构建 ##{build_number} #{build_url}")
        wait_for_jenkins_build(build_url, build_number, target_name)
      end

      def wait_for_jenkins_executable(queue_uri, target_name)
        deadline = Time.now + jenkins_wait_timeout

        loop do
          raise Pod::Informative, "Jenkins #{target_name} 等待队列超时" if Time.now > deadline

          data = jenkins_json(URI.join(queue_uri.to_s, 'api/json'))
          if data['cancelled']
            raise Pod::Informative, "Jenkins #{target_name} 队列任务已取消"
          end

          executable = data['executable']
          return executable if executable && executable['url']

          print_jenkins_progress("排队 #{data['why'] || '等待执行'}")
          sleep jenkins_poll_interval
        end
      end

      def wait_for_jenkins_build(build_url, build_number, target_name)
        deadline = Time.now + jenkins_wait_timeout
        log_offset = 0
        last_progress_at = Time.at(0)

        loop do
          raise Pod::Informative, "Jenkins #{target_name} ##{build_number} 等待构建超时" if Time.now > deadline

          build_uri = URI.join(build_url, 'api/json?tree=building,result,duration,estimatedDuration,timestamp,url,number')
          data = jenkins_json(build_uri)
          log_offset = print_jenkins_progress_log(build_url, log_offset)

          if data['building']
            if Time.now - last_progress_at >= jenkins_progress_interval
              print_jenkins_progress("构建中 ##{build_number} #{format_jenkins_duration(data['duration'])}")
              last_progress_at = Time.now
            end
            sleep jenkins_poll_interval
            next
          end

          result = data['result'].to_s
          duration = format_jenkins_duration(data['duration'])
          if result == 'SUCCESS'
            finish_jenkins_progress
            Pod::UI.puts "【打包结果】成功 #{target_name} ##{build_number} #{duration}"
            return
          end

          finish_jenkins_progress
          if result == 'ABORTED'
            Pod::UI.puts "【打包结果】取消 #{target_name} ##{build_number}"
            raise Pod::Informative, "Jenkins #{target_name} ##{build_number} 打包任务已取消"
          end

          failure_lines = jenkins_failure_lines(build_url)
          report = analyze_jenkins_failure(failure_lines)
          failure_lines.each { |line| Pod::UI.puts "【打包结果】失败原因 #{line}" }
          Pod::UI.puts "【打包结果】失败 #{target_name} ##{build_number} #{result.empty? ? 'UNKNOWN' : result}"
          run_hermes_publish_evolution(
            event: 'publish_failed',
            report: report,
            target_name: target_name,
            build_number: build_number,
            result: result,
            failure_lines: failure_lines,
            auto_fix: nil
          )
          raise JenkinsAutoFixApplied if auto_fix_jenkins_publish_failure(failure_lines, report: report, target_name: target_name, build_number: build_number, result: result)

          raise Pod::Informative, "Jenkins #{target_name} ##{build_number} 发布失败：#{result.empty? ? 'UNKNOWN' : result}"
        end
      end

      def auto_fix_jenkins_publish_failure(failure_lines, report: nil, target_name: nil, build_number: nil, result: nil)
        report ||= analyze_jenkins_failure(failure_lines)
        policy = jenkins_auto_fix_policy(report)
        return unless policy

        job = policy[:job]
        return if job.nil? || job.empty?

        Pod::UI.puts "【自动修复】检测到 #{report[:type]}，#{policy[:message]}：#{job}"
        execute_remote_jenkins_fix_action(
          key: policy[:key],
          title: "#{policy[:message]}：#{job}",
          remote_job: job,
          target_version: policy[:target_version],
          stop_after_success: true
        )
        Pod::UI.puts "【自动修复】#{policy[:success_message]}"
        run_hermes_publish_evolution(
          event: 'auto_fix_succeeded',
          report: report,
          target_name: target_name,
          build_number: build_number,
          result: result,
          failure_lines: failure_lines,
          auto_fix: policy
        )
        true
      rescue => e
        Pod::UI.puts "【自动修复】失败 #{job}：#{e.message}"
        run_hermes_publish_evolution(
          event: 'auto_fix_failed',
          report: report,
          target_name: target_name,
          build_number: build_number,
          result: result,
          failure_lines: failure_lines,
          auto_fix: policy,
          error: e.message
        )
        false
      end

      def jenkins_auto_fix_retry_limit
        value = ENV['COCOAPODS_PODX_AUTO_FIX_RETRY']
        return 1 if value.nil? || value.to_s.strip.empty?

        Integer(value)
      rescue ArgumentError
        1
      end

      def run_hermes_publish_evolution(event:, report:, target_name:, build_number:, result:, failure_lines:, auto_fix:, error: nil)
        return unless jenkins_hermes_enabled?

        case_record = record_jenkins_failure_case(
          event: event,
          report: report,
          target_name: target_name,
          build_number: build_number,
          result: result,
          failure_lines: failure_lines,
          auto_fix: auto_fix,
          error: error
        )
        recent_cases = recent_jenkins_failure_case_summaries(current_fingerprint: case_record && case_record[:fingerprint])

        hermes = hermes_command
        unless hermes
          Pod::UI.puts '【Hermes进化】未检测到 hermes，跳过发布经验沉淀'
          return
        end

        prompt = hermes_publish_evolution_prompt(
          event: event,
          report: report,
          target_name: target_name,
          build_number: build_number,
          result: result,
          failure_lines: failure_lines,
          auto_fix: auto_fix,
          error: error,
          recent_cases: recent_cases
        )
        output, status = Timeout.timeout(hermes_evolution_timeout) do
          Open3.capture2e(hermes, '-z', prompt)
        end

        if status.success?
          summary = safe_jenkins_text(output).lines.map(&:rstrip).reject(&:empty?).first(8)
          if summary.empty?
            Pod::UI.puts '【Hermes进化】已提交发布经验沉淀'
          else
            Pod::UI.puts '【Hermes进化】'
            summary.each { |line| Pod::UI.puts line }
          end
        else
          Pod::UI.puts "【Hermes进化】执行失败：#{safe_jenkins_text(output).lines.first.to_s.strip}"
        end
      rescue Timeout::Error
        Pod::UI.puts '【Hermes进化】超时，已跳过'
      rescue => e
        Pod::UI.puts "【Hermes进化】执行失败：#{e.message}"
      end

      def jenkins_hermes_enabled?
        return false if ENV['COCOAPODS_PODX_HERMES_EVOLUTION'].to_s == '0'

        @jenkins_hermes_analysis == true
      end

      def hermes_evolution_timeout
        ENV.fetch('COCOAPODS_PODX_HERMES_EVOLUTION_TIMEOUT', '20').to_i
      end

      def hermes_publish_evolution_prompt(event:, report:, target_name:, build_number:, result:, failure_lines:, auto_fix:, error:, recent_cases: [])
        sanitized_lines = failure_lines.map { |line| sanitize_hermes_memory_text(line) }.first(20)
        sanitized_fix = auto_fix ? "#{auto_fix[:key]} #{auto_fix[:job] || auto_fix[:message]}" : 'none'
        case_context = recent_cases.empty? ? '暂无历史相似案例。' : recent_cases.join("\n")
        <<~PROMPT
          你是 iOS DevOps 发布流程自我进化助手。请基于本次 Jenkins 发布事件，完成两件事：
          1. 判断这是否是值得沉淀到 Hermes memory 的稳定经验；如果是，请记忆为通用规则。
          2. 输出下一步流程优化建议，重点关注失败分类、自动修复 job、测试用例和文档。

          记忆要求：
          - 只记录稳定、可复用的发布流程经验。
          - 不记录密码、token、证书、内部服务地址、绝对路径、个人信息或完整日志。
          - 使用脱敏后的现象、分类、修复策略和验证方式。

          事件：#{event}
          渠道：#{sanitize_hermes_memory_text(target_name)}
          构建号：#{build_number}
          结果：#{sanitize_hermes_memory_text(result)}
          本地规则分类：#{sanitize_hermes_memory_text(report[:type])}
          本地规则原因：#{sanitize_hermes_memory_text(report[:reason])}
          自动修复：#{sanitize_hermes_memory_text(sanitized_fix)}
          修复错误：#{sanitize_hermes_memory_text(error)}
          关键日志：
          #{sanitized_lines.join("\n")}

          历史案例库摘要：
          #{case_context}

          请用简短中文输出：
          - 记忆状态
          - 可复用经验
          - 后续优化建议
        PROMPT
      end

      def record_jenkins_failure_case(event:, report:, target_name:, build_number:, result:, failure_lines:, auto_fix:, error:)
        store = jenkins_failure_case_store
        return if store.disabled?

        record = jenkins_failure_case_record(
          event: event,
          report: report,
          target_name: target_name,
          build_number: build_number,
          result: result,
          failure_lines: failure_lines,
          auto_fix: auto_fix,
          error: error
        )
        store.append(record)
        Pod::UI.puts "【失败案例库】已记录 #{record[:fingerprint]} #{store.path}"
        record
      rescue => e
        Pod::UI.puts "【失败案例库】写入失败：#{e.message}"
        nil
      end

      def jenkins_failure_case_record(event:, report:, target_name:, build_number:, result:, failure_lines:, auto_fix:, error:)
        evidence = Array(report[:evidence]).map { |line| sanitize_hermes_memory_text(line) }.first(8)
        sanitized_lines = failure_lines.map { |line| sanitize_hermes_memory_text(line) }.first(20)
        fingerprint_source = [
          report[:type],
          report[:reason],
          evidence.join("\n"),
          sanitized_lines.first(5).join("\n")
        ].join("\n")
        {
          schema_version: 1,
          created_at: Time.now.utc.iso8601,
          event: event.to_s,
          job: configured_jenkins_job_name.to_s,
          target: sanitize_hermes_memory_text(target_name),
          build_number: build_number,
          result: sanitize_hermes_memory_text(result),
          type: sanitize_hermes_memory_text(report[:type]),
          reason: sanitize_hermes_memory_text(report[:reason]),
          fingerprint: Digest::SHA256.hexdigest(fingerprint_source)[0, 16],
          evidence: evidence,
          failure_lines: sanitized_lines,
          suggestions: Array(report[:suggestions]).map { |line| sanitize_hermes_memory_text(line) }.first(8),
          auto_fix: jenkins_failure_case_auto_fix(auto_fix),
          error: sanitize_hermes_memory_text(error)
        }
      end

      def jenkins_failure_case_auto_fix(auto_fix)
        return nil unless auto_fix

        {
          key: auto_fix[:key].to_s,
          job: sanitize_hermes_memory_text(auto_fix[:job]),
          message: sanitize_hermes_memory_text(auto_fix[:message]),
          success_message: sanitize_hermes_memory_text(auto_fix[:success_message])
        }
      end

      def recent_jenkins_failure_case_summaries(current_fingerprint: nil, limit: 5)
        jenkins_failure_case_store.recent_summaries(current_fingerprint: current_fingerprint, limit: limit, formatter: lambda do |row|
          fix = row[:auto_fix].is_a?(Hash) ? row[:auto_fix][:key].to_s : ''
          pieces = [
            row[:created_at],
            row[:event],
            row[:type],
            row[:reason],
            fix.empty? ? nil : "auto_fix=#{fix}"
          ].compact
          "- #{truncate_display(pieces.join(' | '), 180)}"
        end)
      rescue => e
        Pod::UI.puts "【失败案例库】读取失败：#{e.message}"
        []
      end

      def jenkins_failure_case_store
        @jenkins_failure_case_store ||= CocoapodsPodx::FailureCaseStore.default
      end

      def sanitize_hermes_memory_text(value)
        text = value.to_s
        text = text.gsub(%r{https?://\S+}, '[URL]')
        text = text.gsub(%r{/(Users|private|var|tmp|Applications|opt|Volumes)/\S+}, '[PATH]')
        text = text.gsub(/([A-Za-z0-9_]*password[A-Za-z0-9_]*\s*[=:]\s*)\S+/i, '\1[REDACTED]')
        text = text.gsub(/([A-Za-z0-9_]*token[A-Za-z0-9_]*\s*[=:]\s*)\S+/i, '\1[REDACTED]')
        text = text.gsub(/([A-Za-z0-9_]*secret[A-Za-z0-9_]*\s*[=:]\s*)\S+/i, '\1[REDACTED]')
        text
      end

      def jenkins_auto_fix_policy(report)
        type = report[:type]
        case type
        when 'CocoaPods 配置'
          job = jenkins_auto_fix_job_name('CONFIG', default: 'pod-upgrade')
          return nil if job.empty?

          {
            key: :jenkins_upgrade_podx,
            job: job,
            target_version: cocoapods_podx_version,
            message: "自动触发 Jenkins 维护 job 升级打包机 cocoapods-podx 到 #{cocoapods_podx_version}",
            success_message: "打包机 cocoapods-podx 已升级到 #{cocoapods_podx_version}，请重新执行 podx publish。"
          }
        when 'CocoaPods 依赖', 'CocoaPods 版本约束'
          jenkins_configured_auto_fix_policy(
            'PODS',
            key: :jenkins_fix_pods,
            message: '自动触发 Jenkins 维护 job 修复 CocoaPods specs/cache',
            success_message: 'Jenkins CocoaPods specs/cache 修复完成，请重新执行 podx publish。'
          )
        when '网络或 Git 服务'
          jenkins_configured_auto_fix_policy(
            'NETWORK',
            key: :jenkins_fix_network,
            message: '自动触发 Jenkins 维护 job 检查网络/Git 服务',
            success_message: 'Jenkins 网络/Git 服务检查完成，请重新执行 podx publish。'
          )
        when '签名/证书'
          jenkins_configured_auto_fix_policy(
            'SIGNING',
            key: :jenkins_fix_signing,
            message: '自动触发 Jenkins 维护 job 修复签名/证书环境',
            success_message: 'Jenkins 签名/证书环境修复完成，请重新执行 podx publish。'
          )
        when 'Xcode/SDK 环境'
          jenkins_configured_auto_fix_policy(
            'XCODE',
            key: :jenkins_fix_xcode,
            message: '自动触发 Jenkins 维护 job 检查 Xcode/SDK 环境',
            success_message: 'Jenkins Xcode/SDK 环境检查完成，请重新执行 podx publish。'
          )
        when 'App Store Framework 元数据'
          jenkins_configured_auto_fix_policy(
            'FRAMEWORK_METADATA',
            key: :jenkins_fix_framework_metadata,
            message: '自动触发 Jenkins 维护 job 修复二进制 framework Info.plist 元数据',
            success_message: 'Jenkins framework 元数据修复完成，请重新执行 podx publish。'
          )
        when '磁盘空间'
          jenkins_configured_auto_fix_policy(
            'DISK',
            key: :jenkins_fix_disk,
            message: '自动触发 Jenkins 维护 job 清理磁盘空间',
            success_message: 'Jenkins 磁盘清理完成，请重新执行 podx publish。'
          )
        when '构建脚本'
          jenkins_configured_auto_fix_policy(
            'SCRIPT',
            key: :jenkins_fix_script_tools,
            message: '自动触发 Jenkins 维护 job 修复构建脚本工具链',
            success_message: 'Jenkins 构建脚本工具链修复完成，请重新执行 podx publish。'
          )
        else
          nil
        end
      end

      def jenkins_configured_auto_fix_policy(env_suffix, key:, message:, success_message:)
        job = jenkins_auto_fix_job_name(env_suffix)
        return nil if job.empty?

        {
          key: key,
          job: job,
          target_version: nil,
          message: message,
          success_message: success_message
        }
      end

      def jenkins_auto_fix_job_name(env_suffix = nil, default: nil)
        specific_key = "COCOAPODS_PODX_AUTO_FIX_#{env_suffix}_JOB" if env_suffix
        value = ENV[specific_key] if specific_key
        value = ENV['COCOAPODS_PODX_AUTO_FIX_JOB'] if value.nil?
        value = default if value.nil?
        value.to_s.strip
      end

      def print_jenkins_progress_log(build_url, offset)
        uri = URI.join(build_url, "logText/progressiveText?start=#{offset}")
        request = Net::HTTP::Get.new(uri)
        apply_jenkins_auth(request)
        response = request_jenkins(uri, request)
        return offset unless response.is_a?(Net::HTTPSuccess)

        response['X-Text-Size'].to_i.nonzero? || offset
      rescue
        offset
      end

      def print_jenkins_progress(message)
        line = "【打包进度】#{truncate_display(message, 100)}"
        if $stdout.tty?
          $stdout.print("\r#{line}#{' ' * 20}")
          $stdout.flush
        else
          Pod::UI.puts line
        end
      end

      def finish_jenkins_progress
        return unless $stdout.tty?

        $stdout.print("\r#{' ' * 140}\r")
        $stdout.flush
      end

      def jenkins_failure_lines(build_url)
        uri = URI.join(build_url, 'consoleText')
        request = Net::HTTP::Get.new(uri)
        apply_jenkins_auth(request)
        response = request_jenkins(uri, request)
        return [] unless response.is_a?(Net::HTTPSuccess)

        lines = safe_jenkins_text(response.body).lines.map { |line| strip_ansi(line).strip }.reject(&:empty?)
        primary_failure = jenkins_primary_failure_lines(lines)
        return primary_failure unless primary_failure.empty?

        matched = lines.select { |line| line.match?(/error:|ERROR|FAIL|FAILED|Exception|Invalid `Podfile` file|CocoaPods could not find|Unable to find a specification|Unable to satisfy the following requirements|Error installing|Jenkins 发布触发失败|构建失败|上传失败|发布失败/i) }
        (matched.empty? ? lines.last(20) : matched.last(20))
      rescue => e
        ["无法读取 Jenkins 失败日志：#{e.message}"]
      end

      def jenkins_primary_failure_lines(lines)
        start_index = lines.index do |line|
          line.match?(/\A\[!\]\s+Invalid `Podfile` file:/i) ||
            line.match?(/\A\[!\]\s+CocoaPods could not find/i) ||
            line.match?(/\A\[!\]\s+Unable to find a specification/i) ||
            line.match?(/\A\[!\]\s+Unable to satisfy the following requirements/i) ||
            line.match?(/\A\[!\]\s+Error installing/i) ||
            line.match?(/Invalid `Podfile` file:/i)
        end
        return [] unless start_index

        result = []
        lines[start_index..].each do |line|
          break if result.size >= 10
          break if result.any? && line.match?(/\ABuild step |^\[description-setter\]|^Finished:/)

          result << line
        end
        result
      end

      def jenkins_json(uri)
        request = Net::HTTP::Get.new(uri)
        apply_jenkins_auth(request)
        response = request_jenkins(uri, request)
        raise Pod::Informative, jenkins_http_error_message(response) unless response.is_a?(Net::HTTPSuccess)

        require 'json'
        JSON.parse(response.body)
      end

      def resolve_jenkins_url(raw_url, base_job_url)
        uri = URI(raw_url)
        return uri unless uri.host == 'localhost' || uri.host == '127.0.0.1'

        base_uri = URI(base_job_url)
        uri.host = base_uri.host
        uri.port = base_uri.port
        uri.scheme = base_uri.scheme
        uri
      end

      def apply_jenkins_auth(request)
        user = ENV['COCOAPODS_PODX_JENKINS_USER'] || ENV['COCOAPODS_OVERLAY_JENKINS_USER'] || ENV['JENKINS_USER']
        token = ENV['COCOAPODS_PODX_JENKINS_TOKEN'] || ENV['COCOAPODS_OVERLAY_JENKINS_TOKEN'] || ENV['JENKINS_TOKEN'] || ENV['JENKINS_PASSWORD']
        request.basic_auth(user, token) if user && token
      end

      def apply_jenkins_crumb(request, build_uri)
        crumb_uri = URI("#{build_uri.scheme}://#{build_uri.host}:#{build_uri.port}/crumbIssuer/api/json")
        crumb_request = Net::HTTP::Get.new(crumb_uri)
        apply_jenkins_auth(crumb_request)
        response = request_jenkins(crumb_uri, crumb_request)
        return unless response.is_a?(Net::HTTPSuccess)

        require 'json'
        crumb = JSON.parse(response.body)
        field = crumb['crumbRequestField']
        value = crumb['crumb']
        request[field] = value if field && value
        apply_jenkins_cookie(request, response)
      rescue
        nil
      end

      def apply_jenkins_cookie(request, response)
        cookies = response.get_fields('Set-Cookie')
        return if cookies.nil? || cookies.empty?

        request['Cookie'] = cookies.map { |cookie| cookie.split(';').first }.join('; ')
      end

      def request_jenkins(uri, request, open_timeout: jenkins_open_timeout, read_timeout: jenkins_read_timeout)
        Net::HTTP.start(
          uri.host,
          uri.port,
          use_ssl: uri.scheme == 'https',
          open_timeout: open_timeout,
          read_timeout: read_timeout
        ) { |http| http.request(request) }
      end

      def jenkins_connection_error?(error)
        jenkins_connection_error_classes.any? { |klass| error.is_a?(klass) }
      end

      def jenkins_connection_error_classes
        errno_classes = %i[
          ECONNREFUSED
          EHOSTUNREACH
          ENETUNREACH
          ETIMEDOUT
          EPERM
        ].map { |name| Errno.const_get(name) if Errno.const_defined?(name) }.compact

        [Net::OpenTimeout, Net::ReadTimeout, Timeout::Error, SocketError] + errno_classes
      end

      def jenkins_connection_error_message(url, error)
        "无法连接 Jenkins：#{url}（#{error.class}: #{error.message}）。请确认当前终端可访问 Jenkins、VPN/内网权限正常；如果是在受限沙箱中执行，请在普通终端执行或授权网络访问。"
      end

      def jenkins_open_timeout
        ENV.fetch('COCOAPODS_PODX_JENKINS_OPEN_TIMEOUT', ENV.fetch('COCOAPODS_OVERLAY_JENKINS_OPEN_TIMEOUT', '15')).to_i
      end

      def jenkins_read_timeout
        ENV.fetch('COCOAPODS_PODX_JENKINS_READ_TIMEOUT', ENV.fetch('COCOAPODS_OVERLAY_JENKINS_READ_TIMEOUT', '60')).to_i
      end

      def jenkins_probe_timeout
        ENV.fetch('COCOAPODS_PODX_JENKINS_PROBE_TIMEOUT', ENV.fetch('COCOAPODS_OVERLAY_JENKINS_PROBE_TIMEOUT', '5')).to_i
      end

      def jenkins_poll_interval
        ENV.fetch('COCOAPODS_PODX_JENKINS_POLL_INTERVAL', ENV.fetch('COCOAPODS_OVERLAY_JENKINS_POLL_INTERVAL', '5')).to_i
      end

      def jenkins_progress_interval
        ENV.fetch('COCOAPODS_PODX_JENKINS_PROGRESS_INTERVAL', ENV.fetch('COCOAPODS_OVERLAY_JENKINS_PROGRESS_INTERVAL', '30')).to_i
      end

      def jenkins_wait_timeout
        ENV.fetch('COCOAPODS_PODX_JENKINS_WAIT_TIMEOUT', ENV.fetch('COCOAPODS_OVERLAY_JENKINS_WAIT_TIMEOUT', '7200')).to_i
      end

      def format_jenkins_duration(milliseconds)
        total_seconds = milliseconds.to_i / 1000
        minutes = total_seconds / 60
        seconds = total_seconds % 60
        minutes.positive? ? "#{minutes}m#{seconds}s" : "#{seconds}s"
      end

      def strip_ansi(text)
        safe_jenkins_text(text).gsub(/\e\[[0-9;]*[A-Za-z]/, '')
      end

      def safe_jenkins_text(text)
        text.to_s.encode('UTF-8', invalid: :replace, undef: :replace, replace: '')
      end

      def jenkins_http_error_message(response)
        message = "Jenkins 发布触发失败：HTTP #{response.code} #{response.message}"
        body = response.body.to_s.strip
        message += "，#{body.lines.first.strip}" unless body.empty?
        if response.code.to_i == 403
          message += '。请确认 Jenkins 用户有构建权限，或设置 COCOAPODS_PODX_JENKINS_USER / COCOAPODS_PODX_JENKINS_TOKEN。'
        end
        message
      end

      def mask_password(value)
        value.to_s.gsub(/[^,]/, '*')
      end

    end
  end
end
