require 'fileutils'
require 'json'
require 'yaml'

module CocoapodsPodx
  module Commands
    module SkillRuntime
      SKILL_FILE = File.join('.podx', 'skills.yml').freeze
      SKILL_HISTORY_FILE = File.join('.podx', 'skill_runs.yml').freeze
      SKILL_HISTORY_LIMIT = 100

      def run_skill_command(entries)
        command = @pod_names.shift.to_s
        command = 'list' if command.empty?

        case command
        when 'init'
          init_podx_skill_library
        when 'list'
          list_podx_skills(@pod_names.shift)
        when 'show'
          show_podx_skill(@pod_names.shift)
        when 'history'
          show_podx_skill_history(@pod_names.shift)
        when 'stats'
          show_podx_skill_stats
        when 'report'
          report_podx_skills
        when 'suggest'
          suggest_podx_skills
        when 'snapshot'
          snapshot_podx_skills
        when 'ci'
          ci_podx_skills(@pod_names.shift)
        when 'doctor'
          doctor_podx_skills
        when 'graph'
          graph_podx_skills
        when 'plan'
          plan_podx_skill(@pod_names.shift)
        when 'lint'
          lint_podx_skills
        when 'verify'
          verify_podx_skill(@pod_names.shift)
        when 'run'
          run_podx_skill(@pod_names.shift, entries)
        else
          raise Pod::Informative, "未知 skill 命令：#{command}，请使用 podx skill list 查看支持范围"
        end
      end

      def podx_skill_definitions
        built_in_skills + project_skill_definitions
      end

      def built_in_skills
        [
          {
            name: 'dependency_audit',
            stage: '依赖治理',
            scene: '依赖巡检',
            entry: 'podx deps + podx doctor',
            verify: 'Podfile/lock/config',
            source: '内置',
            channel: nil
          },
          {
            name: 'release_pgyer',
            stage: '发布',
            scene: '蒲公英发布',
            entry: 'podx publish',
            verify: 'Jenkins/依赖',
            source: '内置',
            channel: 'pgyer'
          },
          {
            name: 'release_testflight',
            stage: '发布',
            scene: 'TestFlight发布',
            entry: 'podx publish tf',
            verify: 'release分支/Jenkins',
            source: '内置',
            channel: 'tf'
          },
          {
            name: 'release_appstore',
            stage: '发布',
            scene: 'AppStore发布',
            entry: 'podx publish app',
            verify: 'release分支/Jenkins',
            source: '内置',
            channel: 'app'
          },
          {
            name: 'diagnose_publish_failure',
            stage: '故障诊断',
            scene: '打包失败诊断',
            entry: 'podx publish doctor',
            verify: 'Jenkins日志',
            source: '内置',
            channel: nil
          },
          {
            name: 'repair_publish_failure',
            stage: '故障修复',
            scene: '打包失败半自动修复',
            entry: 'podx publish fix',
            verify: 'Jenkins日志/修复动作',
            source: '内置',
            channel: nil
          }
        ]
      end

      def init_podx_skill_library
        path = podx_skill_file_path
        if File.exist?(path)
          Pod::UI.puts "podx skill [exists] #{path}"
          return
        end

        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, default_podx_skill_library)
        Pod::UI.puts "podx skill [created] #{path}"
      end

      def list_podx_skills(keyword = nil)
        skills = filter_podx_skills(podx_skill_definitions, keyword)
        rows = skills.map do |skill|
          [skill[:name], skill[:source] || '项目', skill[:stage], skill[:scene], podx_skill_depends_text(skill), skill[:entry], skill[:verify]]
        end
        title = keyword.to_s.strip.empty? ? 'podx skill' : "podx skill #{keyword}"
        print_box_table(title, %w[Skill 来源 阶段 场景 依赖 入口 验证], rows)
        Pod::UI.puts "skill list [done] #{rows.size}"
      end

      def filter_podx_skills(skills, keyword)
        normalized = keyword.to_s.strip.downcase
        return skills if normalized.empty?

        skills.select do |skill|
          [skill[:name], skill[:source], skill[:stage], skill[:scene], skill[:entry], skill[:verify]].any? do |value|
            value.to_s.downcase.include?(normalized)
          end
        end
      end

      def show_podx_skill(name)
        skill = find_podx_skill!(name)
        rows = [
          ['名称', skill[:name]],
          ['来源', skill[:source] || '项目'],
          ['阶段', skill[:stage]],
          ['场景', skill[:scene]],
          ['依赖', podx_skill_depends_text(skill)],
          ['入口', skill[:entry]],
          ['验证', skill[:verify]]
        ]
        Array(skill[:steps]).each_with_index do |step, index|
          rows << ["步骤#{index + 1}", step.to_s]
        end
        print_box_table("skill #{skill[:name]}", %w[字段 内容], rows)
      end

      def verify_podx_skill(name)
        skill = find_podx_skill!(name)
        rows = podx_skill_verify_rows(skill)
        print_box_table("skill verify #{skill[:name]}", %w[检查 结果 说明], rows)
        failures = rows.select { |row| row[1] != 'ok' }
        raise Pod::Informative, "skill #{skill[:name]} 校验失败，请先处理上述问题" if failures.any?
      end

      def doctor_podx_skills
        rows = podx_skill_doctor_rows
        print_box_table('podx skill doctor', %w[Skill 来源 状态 说明], rows)
        summary = rows.each_with_object(Hash.new(0)) { |row, counts| counts[row[2]] += 1 }
        Pod::UI.puts "skill doctor [done] 可用 #{summary['可用']} 警告 #{summary['警告']} 不可用 #{summary['不可用']}"
      end

      def graph_podx_skills
        rows = podx_skill_graph_rows
        print_box_table('podx skill graph', %w[Skill 阶段 依赖], rows)
        Pod::UI.puts "skill graph [done] #{rows.size}"
      end

      def plan_podx_skill(name)
        skill = find_podx_skill!(name)
        validate_podx_skill_plan!(skill)
        rows = podx_skill_plan_rows(skill)
        print_box_table("podx skill plan #{skill[:name]}", %w[顺序 Skill 类型 内容], rows)
        Pod::UI.puts "skill plan [done] #{rows.size}"
      end

      def lint_podx_skills
        rows = podx_skill_lint_rows
        print_box_table('podx skill lint', %w[规则 结果 说明], rows)
        failures = rows.select { |row| row[1] == 'fail' }
        warnings = rows.select { |row| row[1] == 'warn' }
        Pod::UI.puts "skill lint [done] fail #{failures.size} warn #{warnings.size}"
        raise Pod::Informative, 'skill library lint 失败，请先处理上述问题' if failures.any?
      end

      def report_podx_skills
        rows = podx_skill_report_rows
        print_box_table('podx skill report', %w[维度 状态 说明], rows)
        lint_failures = podx_skill_lint_rows.count { |row| row[1] == 'fail' }
        Pod::UI.puts "skill report [done] #{rows.size}"
        raise Pod::Informative, 'skill report 检测到 lint 失败，请先处理上述问题' if lint_failures.positive?
      end

      def suggest_podx_skills
        rows = podx_skill_suggestion_rows
        print_box_table('podx skill suggest', %w[建议 命令 原因], rows)
        Pod::UI.puts "skill suggest [done] #{rows.size}"
      end

      def snapshot_podx_skills
        path = podx_skill_snapshot_path
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, podx_skill_snapshot_markdown)
        Pod::UI.puts "skill snapshot [written] #{path}"
      end

      def ci_podx_skills(mode = nil)
        strict = podx_skill_ci_strict?(mode)
        lint_rows = podx_skill_lint_rows
        report_rows = podx_skill_report_rows
        snapshot_podx_skills
        rows = podx_skill_ci_rows(lint_rows, report_rows, strict: strict)
        json_path = write_podx_skill_ci_json(lint_rows, report_rows, rows, strict: strict)
        rows << ['json', 'ok', json_path]
        print_box_table('podx skill ci', %w[步骤 状态 说明], rows)
        failures = podx_skill_ci_failures(lint_rows, report_rows, strict: strict)
        Pod::UI.puts "skill ci [done] mode #{strict ? 'strict' : 'default'} fail #{failures.size} snapshot #{podx_skill_snapshot_path} json #{json_path}"
        raise Pod::Informative, "skill ci #{strict ? 'strict ' : ''}检测失败，请先处理上述问题" if failures.any?
      end

      def podx_skill_ci_rows(lint_rows = podx_skill_lint_rows, report_rows = podx_skill_report_rows, strict: false)
        [
          ['mode', 'ok', strict ? 'strict' : 'default'],
          ['lint', podx_report_status(lint_rows), podx_report_lint_detail(lint_rows)],
          ['report', podx_report_status(report_rows), "#{report_rows.size} 项"],
          ['snapshot', 'ok', podx_skill_snapshot_path]
        ]
      end

      def write_podx_skill_ci_json(lint_rows, report_rows, ci_rows, strict: false)
        path = podx_skill_ci_json_path
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.pretty_generate(podx_skill_ci_payload(lint_rows, report_rows, ci_rows, strict: strict)) + "\n")
        path
      end

      def podx_skill_ci_json_path
        File.join(project_directory, '.podx', 'skill_ci.json')
      end

      def podx_skill_ci_payload(lint_rows = podx_skill_lint_rows, report_rows = podx_skill_report_rows, ci_rows = podx_skill_ci_rows(lint_rows, report_rows), strict: false)
        {
          generated_at: Time.now.strftime('%Y-%m-%d %H:%M:%S'),
          project: project_directory,
          strict: strict,
          status: podx_skill_ci_failures(lint_rows, report_rows, strict: strict).any? ? 'fail' : podx_report_status(report_rows),
          snapshot_path: podx_skill_snapshot_path,
          json_path: podx_skill_ci_json_path,
          summary: podx_rows_to_hashes(%w[step status detail], ci_rows),
          lint: podx_rows_to_hashes(%w[rule status detail], lint_rows),
          report: podx_rows_to_hashes(%w[dimension status detail], report_rows),
          suggestions: podx_rows_to_hashes(%w[action command reason], podx_skill_suggestion_rows),
          skills: podx_rows_to_hashes(%w[name source stage scene depends_on entry verify], podx_skill_catalog_rows),
          stats: podx_rows_to_hashes(%w[skill total success failed success_rate last_status last_time], podx_skill_stats_rows)
        }
      end

      def podx_skill_ci_strict?(mode)
        normalized = mode.to_s.strip
        return false if normalized.empty?
        return true if normalized == 'strict' || normalized == '--strict'

        raise Pod::Informative, "未知 skill ci 模式：#{normalized}，支持：podx skill ci 或 podx skill ci strict"
      end

      def podx_skill_ci_failures(lint_rows, report_rows, strict: false)
        failures = lint_rows.select { |row| row[1] == 'fail' }
        failures += report_rows.select { |row| row[1] == 'fail' } if strict
        failures
      end

      def podx_rows_to_hashes(headers, rows)
        rows.map do |row|
          headers.each_with_index.each_with_object({}) do |(header, index), item|
            item[header] = row[index] || '-'
          end
        end
      end

      def podx_skill_snapshot_path
        File.join(project_directory, '.podx', 'skill_snapshot.md')
      end

      def podx_skill_snapshot_markdown
        sections = []
        sections << '# podx skill snapshot'
        sections << ''
        sections << "- generated_at: #{Time.now.strftime('%Y-%m-%d %H:%M:%S')}"
        sections << "- project: #{project_directory}"
        sections << ''
        sections << '## Governance Report'
        sections << podx_markdown_table(%w[维度 状态 说明], podx_skill_report_rows)
        sections << ''
        sections << '## Suggestions'
        sections << podx_markdown_table(%w[建议 命令 原因], podx_skill_suggestion_rows)
        sections << ''
        sections << '## Lint'
        sections << podx_markdown_table(%w[规则 结果 说明], podx_skill_lint_rows)
        sections << ''
        sections << '## Skill Catalog'
        sections << podx_markdown_table(%w[Skill 来源 阶段 场景 依赖 入口 验证], podx_skill_catalog_rows)
        sections << ''
        sections << '## Skill Graph'
        sections << podx_markdown_table(%w[Skill 阶段 依赖], podx_skill_graph_rows)
        sections << ''
        sections << '## Run Stats'
        sections << podx_markdown_table(%w[Skill 总次数 成功 失败 成功率 最近状态 最近时间], podx_skill_stats_rows)
        sections << ''
        sections.join("\n")
      end

      def podx_skill_catalog_rows
        podx_skill_definitions.map do |skill|
          [
            skill[:name],
            skill[:source] || '项目',
            skill[:stage],
            skill[:scene],
            podx_skill_depends_text(skill),
            skill[:entry],
            skill[:verify]
          ]
        end
      end

      def podx_markdown_table(headers, rows)
        safe_rows = rows.empty? ? [Array.new(headers.size, '-')] : rows
        lines = []
        lines << "| #{headers.map { |header| podx_markdown_cell(header) }.join(' | ')} |"
        lines << "| #{headers.map { '---' }.join(' | ')} |"
        safe_rows.each do |row|
          values = row.first(headers.size)
          values += Array.new(headers.size - values.size, '-')
          lines << "| #{values.map { |value| podx_markdown_cell(value) }.join(' | ')} |"
        end
        lines.join("\n")
      end

      def podx_markdown_cell(value)
        text = value.to_s.strip
        text = '-' if text.empty?
        text.gsub('|', '\\|').gsub("\n", '<br>')
      end

      def podx_skill_suggestion_rows
        suggestions = []
        lint_rows = podx_skill_lint_rows
        doctor_rows = podx_skill_doctor_rows
        history = load_podx_skill_history

        unless File.exist?(podx_skill_file_path)
          suggestions << ['初始化项目技能库', 'podx skill init', '生成 .podx/skills.yml，开始沉淀团队流程']
        end

        if lint_rows.any? { |row| row[1] == 'fail' }
          suggestions << ['修复技能库定义', 'podx skill lint', '存在重复名称、未知依赖、循环依赖或非法步骤']
        elsif lint_rows.any? { |row| row[1] == 'warn' }
          suggestions << ['完善技能库元数据', 'podx skill lint', '存在 warning，可补齐项目技能库或技能描述信息']
        end

        unavailable = doctor_rows.select { |row| row[2] == '不可用' }
        warnings = doctor_rows.select { |row| row[2] == '警告' }
        if unavailable.any?
          suggestions << ['处理不可用技能', 'podx skill doctor', "不可用 #{unavailable.size} 个：#{unavailable.map(&:first).first(3).join(', ')}"]
        elsif warnings.any?
          suggestions << ['确认技能运行环境', 'podx skill doctor', "存在 #{warnings.size} 个环境 warning"]
        end

        if history.empty?
          suggestions << ['建立运行基线', 'podx skill run dependency_audit', '暂无技能运行历史，建议先跑一次依赖巡检']
        elsif podx_skill_overall_success_rate(history) < 80
          suggestions << ['复盘失败技能', 'podx skill history 20', "总体成功率 #{podx_report_success_rate(history)}，建议沉淀修复经验"]
        end

        suggestions << ['保持治理节奏', 'podx skill report', '当前没有高优先级建议，定期查看治理总览'] if suggestions.empty?
        suggestions
      end

      def podx_skill_report_rows
        skills = podx_skill_definitions
        lint_rows = podx_skill_lint_rows
        doctor_rows = podx_skill_doctor_rows
        stats_rows = podx_skill_stats_rows
        history = load_podx_skill_history
        [
          ['技能数量', 'ok', "#{skills.size} 个"],
          ['项目技能库', File.exist?(podx_skill_file_path) ? 'ok' : 'warn', File.exist?(podx_skill_file_path) ? podx_skill_file_path : '未初始化 .podx/skills.yml'],
          ['定义规范', podx_report_status(lint_rows), podx_report_lint_detail(lint_rows)],
          ['环境可用性', podx_report_doctor_status(doctor_rows), podx_report_doctor_detail(doctor_rows)],
          ['运行历史', history.empty? ? 'warn' : 'ok', history.empty? ? '暂无运行历史' : "#{history.size} 次"],
          ['总体成功率', history.empty? ? 'warn' : 'ok', podx_report_success_rate(history)]
        ]
      end

      def podx_report_status(rows)
        return 'fail' if rows.any? { |row| row[1] == 'fail' }
        return 'warn' if rows.any? { |row| row[1] == 'warn' }

        'ok'
      end

      def podx_report_lint_detail(rows)
        failures = rows.count { |row| row[1] == 'fail' }
        warnings = rows.count { |row| row[1] == 'warn' }
        "fail #{failures}, warn #{warnings}"
      end

      def podx_report_doctor_status(rows)
        return 'fail' if rows.any? { |row| row[2] == '不可用' }
        return 'warn' if rows.any? { |row| row[2] == '警告' }

        'ok'
      end

      def podx_report_doctor_detail(rows)
        available = rows.count { |row| row[2] == '可用' }
        warnings = rows.count { |row| row[2] == '警告' }
        unavailable = rows.count { |row| row[2] == '不可用' }
        "可用 #{available}, 警告 #{warnings}, 不可用 #{unavailable}"
      end

      def podx_report_success_rate(history)
        success_count = history.count { |run| run['status'] == 'success' }
        "#{podx_skill_success_rate(success_count, history.size)} (#{success_count}/#{history.size})"
      end

      def podx_skill_overall_success_rate(history)
        return 0 if history.empty?

        success_count = history.count { |run| run['status'] == 'success' }
        success_count.to_f * 100 / history.size
      end

      def podx_skill_lint_rows
        rows = []
        rows.concat(podx_skill_name_lint_rows)
        podx_skill_definitions.each do |skill|
          rows.concat(podx_skill_definition_lint_rows(skill))
        end
        rows << ['project_file', 'ok', podx_skill_file_path] if File.exist?(podx_skill_file_path)
        rows << ['project_file', 'warn', "未找到项目级 skill 文件：#{podx_skill_file_path}"] unless File.exist?(podx_skill_file_path)
        rows
      end

      def podx_skill_name_lint_rows
        rows = []
        skills = podx_skill_definitions
        blank_names = skills.select { |skill| skill[:name].to_s.strip.empty? }
        rows << ['name', 'fail', '存在空 skill 名称'] if blank_names.any?

        duplicate_names = skills.map { |skill| skill[:name] }.group_by(&:itself).select { |_, values| values.size > 1 }.keys
        duplicate_names.each do |name|
          rows << ['name', 'fail', "skill 名称重复：#{name}"]
        end
        rows << ['name', 'ok', "#{skills.size} 个 skill 名称唯一"] if blank_names.empty? && duplicate_names.empty?
        rows
      end

      def podx_skill_definition_lint_rows(skill)
        rows = []
        rows << ['metadata', 'warn', "#{skill[:name]} 缺少 stage"] if skill[:stage].to_s.strip.empty?
        rows << ['metadata', 'warn', "#{skill[:name]} 缺少 scene"] if skill[:scene].to_s.strip.empty? || skill[:scene] == '-'
        rows.concat(podx_skill_dependency_verify_rows(skill))
        rows.concat(project_skill_step_verify_rows(skill)) if project_skill?(skill)
        rows
      end

      def podx_skill_plan_rows(skill)
        rows = []
        collect_podx_skill_plan_rows(skill, rows, {})
        rows.each_with_index.map do |row, index|
          [index + 1, row[:skill], row[:type], row[:content]]
        end
      end

      def collect_podx_skill_plan_rows(skill, rows, visited)
        return if visited[skill[:name]]

        visited[skill[:name]] = true
        Array(skill[:depends_on]).each do |dependency|
          collect_podx_skill_plan_rows(find_podx_skill!(dependency), rows, visited)
        end

        steps = Array(skill[:steps])
        if steps.empty?
          entry = skill[:entry].to_s.strip
          rows << { skill: skill[:name], type: '入口', content: entry.empty? ? '-' : entry }
        else
          steps.each do |step|
            rows << { skill: skill[:name], type: '步骤', content: step.to_s }
          end
        end
      end

      def validate_podx_skill_plan!(skill)
        rows = podx_skill_plan_validate_rows(skill)
        failures = rows.select { |row| row[1] != 'ok' }
        return if failures.empty?

        message = failures.map { |row| "#{row[0]}: #{row[2]}" }.join('；')
        raise Pod::Informative, "skill #{skill[:name]} 执行计划不可用：#{message}"
      end

      def podx_skill_plan_validate_rows(skill, visited = {})
        return [] if visited[skill[:name]]

        visited[skill[:name]] = true
        rows = podx_skill_dependency_verify_rows(skill)
        rows.concat(project_skill_step_verify_rows(skill)) if project_skill?(skill)
        Array(skill[:depends_on]).each do |dependency|
          dependency_skill = podx_skill_definitions.find { |item| item[:name] == dependency }
          rows.concat(podx_skill_plan_validate_rows(dependency_skill, visited)) if dependency_skill
        end
        rows
      end

      def podx_skill_graph_rows
        podx_skill_definitions.map do |skill|
          [skill[:name], skill[:stage], podx_skill_depends_text(skill)]
        end
      end

      def podx_skill_doctor_rows
        podx_skill_definitions.map do |skill|
          verify_rows = podx_skill_verify_rows(skill)
          status, detail = skill_status_from_verify_rows(verify_rows)
          [skill[:name], skill[:source] || '项目', status, detail]
        end
      end

      def skill_status_from_verify_rows(rows)
        failure = rows.find { |row| row[1] == 'fail' }
        return ['不可用', "#{failure[0]}: #{failure[2]}"] if failure

        warning = rows.find { |row| row[1] == 'warn' }
        return ['警告', "#{warning[0]}: #{warning[2]}"] if warning

        ['可用', '前置条件通过']
      end

      def run_podx_skill(name, entries)
        skill = find_podx_skill!(name)
        started_at = Time.now
        status = 'success'
        detail = '完成'

        begin
          verify_podx_skill(skill[:name])

          case skill[:name]
          when 'dependency_audit'
            show_dependency_report
            doctor_overlay(entries)
          when 'release_pgyer', 'release_testflight', 'release_appstore'
            @pod_names = [skill[:channel]]
            publish_to_jenkins
          when 'diagnose_publish_failure'
            @jenkins_log_build = @pod_names.shift
            doctor_jenkins_build
          when 'repair_publish_failure'
            @jenkins_log_build = @pod_names.shift
            fix_jenkins_build
          else
            run_project_podx_skill(skill)
          end
        rescue => e
          status = 'failed'
          detail = e.message
          raise
        ensure
          record_podx_skill_run(skill, status: status, started_at: started_at, detail: detail) unless @dry_run
        end
      end

      def find_podx_skill!(name)
        normalized = name.to_s.strip
        raise Pod::Informative, '请指定 skill 名称，例如：podx skill run dependency_audit' if normalized.empty?

        skill = podx_skill_definitions.find { |item| item[:name] == normalized }
        raise Pod::Informative, "未知 skill：#{normalized}，请使用 podx skill list 查看支持范围" unless skill

        skill
      end

      def podx_skill_verify_rows(skill)
        rows = []
        rows << skill_file_check_row('Podfile', podfile_path)
        rows << skill_file_check_row('podx.config.yml', config_path)
        rows << skill_file_check_row('Podfile.lock', File.join(project_directory, 'Podfile.lock')) if skill[:name] == 'dependency_audit'
        rows << skill_jenkins_check_row if skill[:name].start_with?('release_') || skill[:name].include?('publish_failure')
        rows << skill_release_branch_check_row if %w[release_testflight release_appstore].include?(skill[:name])
        rows.concat(podx_skill_dependency_verify_rows(skill))
        rows.concat(project_skill_step_verify_rows(skill)) if project_skill?(skill)
        rows
      end

      def podx_skill_dependency_verify_rows(skill)
        depends_on = Array(skill[:depends_on])
        return [] if depends_on.empty?

        known_names = podx_skill_definitions.map { |item| item[:name] }
        rows = depends_on.map do |dependency|
          if known_names.include?(dependency)
            ["depends_on:#{dependency}", 'ok', dependency]
          else
            ["depends_on:#{dependency}", 'fail', "未知依赖 skill：#{dependency}"]
          end
        end
        cycle = podx_skill_dependency_cycle(skill[:name])
        rows << ['depends_on', 'fail', "检测到循环依赖：#{cycle.join(' -> ')}"] if cycle
        rows
      end

      def skill_file_check_row(label, path)
        if File.exist?(path)
          [label, 'ok', path]
        else
          [label, 'fail', "文件不存在：#{path}"]
        end
      end

      def skill_jenkins_check_row
        [ 'Jenkins', 'ok', selected_jenkins_job_url ]
      rescue
        [ 'Jenkins', 'warn', '未能提前确认 Jenkins 地址，执行时会按主备地址探测' ]
      end

      def skill_release_branch_check_row
        branch = @publish_branch || (respond_to?(:main_app_branch) ? main_app_branch : nil)
        if branch.to_s.match?(%r{\Arelease/\d+\.\d+\.\d+\z})
          [ 'release分支', 'ok', branch ]
        else
          [ 'release分支', 'fail', 'tf/app 仅允许 release/x.x.x；可使用 --branch release/x.x.x' ]
        end
      end

      def project_skill_definitions
        raw = load_project_skill_file
        Array(raw['skills']).map do |item|
          skill = item.transform_keys(&:to_sym)
          skill[:name] = skill[:name].to_s
          skill[:stage] ||= '项目'
          skill[:scene] ||= '-'
          skill[:entry] ||= Array(skill[:steps]).join(' && ')
          skill[:verify] ||= 'steps'
          skill[:depends_on] = Array(skill[:depends_on]).map(&:to_s)
          skill[:source] = '项目'
          skill
        end
      end

      def load_project_skill_file
        path = podx_skill_file_path
        return {} unless File.exist?(path)

        YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false) || {}
      rescue Psych::SyntaxError => e
        raise Pod::Informative, "skill 文件解析失败：#{e.message}"
      end

      def podx_skill_file_path
        File.join(project_directory, SKILL_FILE)
      end

      def podx_skill_history_path
        File.join(project_directory, SKILL_HISTORY_FILE)
      end

      def project_skill?(skill)
        (skill[:source] || '项目') == '项目'
      end

      def podx_skill_depends_text(skill)
        depends_on = Array(skill[:depends_on])
        depends_on.empty? ? '-' : depends_on.join(', ')
      end

      def podx_skill_dependency_cycle(start_name)
        visit_podx_skill_dependency(start_name, [], {})
      end

      def visit_podx_skill_dependency(name, stack, visited)
        return nil if visited[name]
        return stack[stack.index(name)..] + [name] if stack.include?(name)

        skill = podx_skill_definitions.find { |item| item[:name] == name }
        return nil unless skill

        Array(skill[:depends_on]).each do |dependency|
          cycle = visit_podx_skill_dependency(dependency, stack + [name], visited)
          return cycle if cycle
        end
        visited[name] = true
        nil
      end

      def project_skill_step_verify_rows(skill)
        steps = Array(skill[:steps])
        rows = []
        rows << if steps.empty?
          if Array(skill[:depends_on]).empty?
            ['steps', 'fail', '项目 skill 缺少 steps']
          else
            ['steps', 'ok', '由 depends_on 编排']
          end
        else
          ['steps', 'ok', "#{steps.size} 个步骤"]
        end
        steps.each_with_index do |step, index|
          command = step.to_s.strip
          if allowed_project_skill_step?(command)
            rows << ["step#{index + 1}", 'ok', command]
          else
            rows << ["step#{index + 1}", 'fail', "不支持的命令：#{command}"]
          end
        end
        rows
      end

      def allowed_project_skill_step?(command)
        command.match?(/\A(?:podx|mgit|pod)\s+/)
      end

      def run_project_podx_skill(skill)
        Array(skill[:depends_on]).each do |dependency|
          Pod::UI.puts "skill [depends_on] #{dependency}"
          run_podx_skill(dependency, [])
        end

        Array(skill[:steps]).each do |step|
          command = step.to_s.strip
          if @dry_run
            Pod::UI.puts "skill [dry-run] #{command}"
            next
          end

          Pod::UI.puts "skill [run] #{command}"
          success = system(command, chdir: project_directory)
          raise Pod::Informative, "skill #{skill[:name]} 执行失败：#{command}" unless success
        end
      end

      def record_podx_skill_run(skill, status:, started_at:, detail:)
        ended_at = Time.now
        history = load_podx_skill_history
        history << {
          'skill' => skill[:name],
          'source' => skill[:source] || '项目',
          'status' => status,
          'started_at' => started_at.iso8601,
          'duration' => format('%.2fs', ended_at - started_at),
          'detail' => detail.to_s.lines.first.to_s.strip
        }
        history = history.last(SKILL_HISTORY_LIMIT)

        path = podx_skill_history_path
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, { 'runs' => history }.to_yaml)
      end

      def load_podx_skill_history
        path = podx_skill_history_path
        return [] unless File.exist?(path)

        raw = YAML.safe_load(File.read(path), permitted_classes: [], permitted_symbols: [], aliases: false) || {}
        Array(raw['runs'])
      rescue Psych::SyntaxError => e
        raise Pod::Informative, "skill history 解析失败：#{e.message}"
      end

      def show_podx_skill_history(limit_value)
        limit = limit_value.to_i.positive? ? limit_value.to_i : 10
        rows = load_podx_skill_history.last(limit).reverse.map do |run|
          [
            run['skill'],
            run['source'] || '-',
            run['status'],
            run['duration'] || '-',
            run['started_at'] || '-',
            run['detail'] || '-'
          ]
        end
        print_box_table('podx skill history', %w[Skill 来源 状态 耗时 时间 说明], rows)
        Pod::UI.puts "skill history [done] #{rows.size}"
      end

      def show_podx_skill_stats
        rows = podx_skill_stats_rows
        print_box_table('podx skill stats', %w[Skill 总次数 成功 失败 成功率 最近状态 最近时间], rows)
        Pod::UI.puts "skill stats [done] #{rows.size}"
      end

      def podx_skill_stats_rows
        grouped = load_podx_skill_history.group_by { |run| run['skill'].to_s }
        grouped.keys.sort.map do |skill_name|
          runs = grouped[skill_name]
          success_count = runs.count { |run| run['status'] == 'success' }
          failed_count = runs.count { |run| run['status'] == 'failed' }
          total_count = runs.size
          last_run = runs.last || {}
          [
            skill_name,
            total_count,
            success_count,
            failed_count,
            podx_skill_success_rate(success_count, total_count),
            last_run['status'] || '-',
            last_run['started_at'] || '-'
          ]
        end
      end

      def podx_skill_success_rate(success_count, total_count)
        return '-' if total_count.to_i.zero?

        format('%.0f%%', success_count.to_f * 100 / total_count)
      end

      def default_podx_skill_library
        <<~YAML
          # 工程级 skill library。
          # 只支持浅层步骤，steps 中建议使用 podx / mgit / pod 命令。
          skills:
            - name: local_dependency_audit
              stage: 依赖治理
              scene: 本地依赖巡检
              entry: podx deps + podx doctor
              verify: Podfile/lock/config
              steps:
                - podx deps
                - podx doctor
            - name: local_publish_precheck
              stage: 发布
              scene: 发布前巡检
              entry: podx deps + mgit status
              verify: Podfile/config/git
              steps:
                - podx deps
                - mgit status
            - name: local_release_readiness
              stage: 发布
              scene: 发布准备度检查
              entry: local_dependency_audit + local_publish_precheck
              verify: composed skills
              depends_on:
                - local_dependency_audit
                - local_publish_precheck
        YAML
      end
    end
  end
end
