require 'fileutils'
require 'json'
require 'time'
require 'yaml'

module CocoapodsPodx
  module Commands
    module PipelineRuntime
      def show_pipeline_map
        command = @pod_names.shift.to_s if defined?(@pod_names)
        command = 'map' if command.to_s.empty?

        case command
        when 'map', 'list'
          git_action_print_table('pipeline 能力地图', %w[阶段 能力 命令 产物], pipeline_rows)
        when 'ci'
          git_action_print_table('pipeline ci 模板', %w[顺序 阶段 命令 失败处理], pipeline_ci_rows)
        when 'flow', 'main-flow', 'main'
          flow_pipeline
        when 'script', 'ci-script'
          write_pipeline_ci_script
        when 'doctor', 'check'
          doctor_pipeline
        when 'snapshot'
          snapshot_pipeline
        when 'report'
          report_pipeline
        when 'status', 'summary'
          status_pipeline
        when 'gate'
          gate_pipeline
        when 'policy'
          policy_pipeline
        when 'readiness', 'ready'
          readiness_pipeline
        else
          raise Pod::Informative, "未知 pipeline 命令：#{command}，支持：podx pipeline、podx pipeline flow、podx pipeline ci、podx pipeline script、podx pipeline doctor、podx pipeline snapshot、podx pipeline report、podx pipeline status、podx pipeline gate、podx pipeline policy、podx pipeline readiness"
        end
      end

      def pipeline_rows
        [
          ['开发准备', '工程/本地组件体检', 'podx doctor', '-'],
          ['开发准备', '多仓库状态巡检', 'mgit status', '-'],
          ['依赖治理', '依赖版本与组件关系', 'podx deps', '-'],
          ['规则门禁', '工程规则 CI 门禁', 'podx rules ci', '.podx/rules_snapshot.json'],
          ['技能门禁', '团队技能库 CI 门禁', 'podx skill ci strict', '.podx/skill_ci.json'],
          ['AI 图谱', '更新图谱并检查影响面', 'podx graph', 'codegraph/code-review-graph'],
          ['发布准备', '多仓库发布分支编排', 'mgit publish release/x.x.x', '-'],
          ['发布执行', 'Jenkins 发布触发', 'podx publish [pgyer|tf|app]', '-'],
          ['发布观测', '构建历史和日志', 'podx publish history/log', '-'],
          ['失败诊断', 'Jenkins 失败分析', 'podx publish doctor', '-'],
          ['半自动修复', '低风险失败修复', 'podx publish fix', '-']
        ]
      end

      def pipeline_ci_rows
        [
          ['1', '工程体检', 'podx doctor', '修复配置或本地组件状态'],
          ['2', '多仓库状态', 'mgit status', '确认未提交变更和分支状态'],
          ['3', '依赖关系', 'podx deps', '检查依赖分支/版本是否符合预期'],
          ['4', '规则门禁', 'podx rules ci', '执行 podx rules sync 后重新检查'],
          ['5', '技能门禁', 'podx skill ci strict', '修复技能库定义或运行记录'],
          ['6', 'AI 图谱', 'podx graph', '更新图谱并复查影响面'],
          ['7', '流程快照', 'podx pipeline snapshot', '更新 pipeline 机器可读快照'],
          ['8', '流程报告', 'podx pipeline report', '更新 pipeline 人可读报告'],
          ['9', '总门禁', 'podx pipeline gate', '按建议修复失败项后重试']
        ]
      end

      def pipeline_main_flow_rows
        [
          ['开发主流程', '1', '同步主工程和本地组件', 'mgit pull'],
          ['开发主流程', '2', '检查本地多仓库状态', 'mgit status'],
          ['开发主流程', '3', '安装或更新 Pods 依赖', 'podx install / podx update NAME'],
          ['开发主流程', '4', '提交本地组件变更', 'mgit add . && mgit commit -m "msg" && mgit push'],
          ['发布主流程', '1', '编排 release 分支和版本号', 'mgit publish release/x.x.x'],
          ['发布主流程', '2', '执行发布前准入检查', 'podx pipeline readiness'],
          ['发布主流程', '3', '触发 Jenkins 打包', 'podx publish [pgyer|tf|app]'],
          ['发布主流程', '4', '查看构建历史和日志', 'podx publish history/log'],
          ['发布主流程', '5', '诊断或修复失败构建', 'podx publish doctor/fix']
        ]
      end

      def flow_pipeline
        git_action_print_table('pipeline 主流程', %w[流程 顺序 动作 命令], pipeline_main_flow_rows)
      end

      def write_pipeline_ci_script
        path = pipeline_ci_script_path
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, pipeline_ci_script_content)
        FileUtils.chmod('+x', path)
        git_action_print_table('pipeline script', %w[项目 状态 路径], [['ci', '已生成', path]])
        Pod::UI.puts "【pipeline script】#{path}"
      end

      def doctor_pipeline
        rows = pipeline_doctor_rows
        git_action_print_table('pipeline doctor', %w[项目 状态 说明], rows)
        failures = rows.select { |row| row[1] != '通过' }
        Pod::UI.puts "【pipeline doctor】失败 #{failures.size} 个"
        raise Pod::Informative, 'pipeline doctor 失败，请执行 podx pipeline script 更新团队 CI 脚本' if failures.any?
      end

      def snapshot_pipeline
        path = pipeline_snapshot_path
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, JSON.pretty_generate(pipeline_snapshot_payload) + "\n")
        git_action_print_table('pipeline snapshot', %w[项目 状态 路径], [['pipeline', '已生成', path]])
        Pod::UI.puts "【pipeline snapshot】#{path}"
      end

      def report_pipeline
        path = pipeline_report_path
        FileUtils.mkdir_p(File.dirname(path))
        File.write(path, pipeline_report_markdown)
        git_action_print_table('pipeline report', %w[项目 状态 路径], [['pipeline', '已生成', path]])
        Pod::UI.puts "【pipeline report】#{path}"
      end

      def status_pipeline
        rows = pipeline_status_rows
        git_action_print_table('pipeline status', %w[维度 状态 产物], rows)
        failures = rows.select { |row| row[1] != '通过' }
        Pod::UI.puts "【pipeline status】异常 #{failures.size} 个"
      end

      def gate_pipeline
        rows = pipeline_gate_rows
        git_action_print_table('pipeline gate', %w[维度 状态 建议], rows)
        failures = rows.select { |row| row[1] != '通过' }
        Pod::UI.puts "【pipeline gate】#{failures.empty? ? '通过' : "失败 #{failures.size} 个"}"
        return if failures.empty?

        raise Pod::Informative, 'pipeline gate 失败，请按建议修复后重试'
      end

      def policy_pipeline
        git_action_print_table('pipeline policy', %w[渠道 门禁 分支规则 失败行为], pipeline_policy_rows)
      end

      def readiness_pipeline
        git_action_print_table('pipeline readiness', %w[渠道 门禁 准入 说明], pipeline_readiness_rows)
      end

      def pipeline_readiness_rows
        failure_count = pipeline_gate_rows.count { |row| row[1] != '通过' }
        pipeline_policy_rows.map do |row|
          channel = row[0]
          mode = row[1]
          [channel, mode, pipeline_readiness_result(mode, failure_count), pipeline_readiness_detail(mode, failure_count)]
        end
      end

      def pipeline_policy_rows
        enabled = pipeline_publish_gate_enabled?
        strategy = pipeline_publish_gate_strategy
        [
          ['蒲公英', enabled ? strategy.fetch('pgyer') : 'off', '任意远端分支', pipeline_policy_failure_action(enabled ? strategy.fetch('pgyer') : 'off')],
          ['TestFlight', enabled ? strategy.fetch('testflight') : 'off', 'release/x.x.x', pipeline_policy_failure_action(enabled ? strategy.fetch('testflight') : 'off')],
          ['AppStore', enabled ? strategy.fetch('appstore') : 'off', 'release/x.x.x', pipeline_policy_failure_action(enabled ? strategy.fetch('appstore') : 'off')],
          ['Framework', enabled ? strategy.fetch('framework') : 'off', '任意远端分支', pipeline_policy_failure_action(enabled ? strategy.fetch('framework') : 'off')]
        ]
      end

      def pipeline_readiness_result(mode, failure_count)
        return '阻断' if mode == 'strict' && failure_count.positive?

        '可发布'
      end

      def pipeline_readiness_detail(mode, failure_count)
        return '未开启预检' if mode == 'off'
        return '预检通过' if failure_count.zero?
        return "告警 #{failure_count} 个" if mode == 'warn'

        "失败 #{failure_count} 个"
      end

      def pipeline_gate_rows
        pipeline_status_rows.map do |row|
          name = row[0]
          status = row[1]
          [name, status, pipeline_gate_action(name, status)]
        end
      end

      def pipeline_status_rows
        [
          pipeline_json_status_row('规则门禁', File.join(project_directory, '.podx', 'rules_snapshot.json')),
          pipeline_json_status_row('技能门禁', File.join(project_directory, '.podx', 'skill_ci.json')),
          pipeline_json_status_row('流程快照', pipeline_snapshot_path),
          pipeline_file_status_row('流程报告', pipeline_report_path)
        ]
      end

      def pipeline_json_status_row(name, path)
        return [name, '缺失', path] unless File.exist?(path)

        status = JSON.parse(File.read(path))['status'].to_s
        [name, pipeline_status_label(status), path]
      rescue
        [name, '异常', path]
      end

      def pipeline_file_status_row(name, path)
        [name, File.exist?(path) ? '通过' : '缺失', path]
      end

      def pipeline_status_label(status)
        case status
        when 'pass', 'ok'
          '通过'
        when 'fail'
          '失败'
        else
          status.empty? ? '异常' : status
        end
      end

      def pipeline_gate_action(name, status)
        return '可继续' if status == '通过'

        case name
        when '规则门禁'
          '执行 podx rules sync && podx rules ci'
        when '技能门禁'
          '执行 podx skill init 或 podx skill ci strict'
        when '流程快照'
          '执行 podx pipeline script && podx pipeline snapshot'
        when '流程报告'
          '执行 podx pipeline report'
        else
          '检查对应产物'
        end
      end

      def pipeline_policy_failure_action(mode)
        case mode
        when 'strict'
          '失败阻断'
        when 'warn'
          '告警继续'
        else
          '不预检'
        end
      end

      def pipeline_publish_gate_enabled?
        value = pipeline_project_config[:publish_pipeline_gate]
        value == true || value.to_s == 'true' || value.to_s == '1'
      end

      def pipeline_publish_gate_strategy
        defaults = {
          'pgyer' => 'warn',
          'testflight' => 'strict',
          'appstore' => 'strict',
          'framework' => 'warn'
        }
        raw = pipeline_project_config[:publish_pipeline_gate_strategy]
        raw = {} unless raw.is_a?(Hash)
        raw.each_with_object(defaults.dup) do |(key, value), memo|
          mode = value == false ? 'off' : value.to_s.strip.downcase
          memo[key.to_s.strip.downcase] = mode if %w[off warn strict].include?(mode)
        end
      end

      def pipeline_project_config
        return @pipeline_project_config if defined?(@pipeline_project_config)

        @pipeline_project_config = begin
          config_file = respond_to?(:project_directory) ? File.join(project_directory, 'podx.config.yml') : nil
          if defined?(CocoapodsPodx::Runtime)
            product_line = instance_variable_defined?(:@product_line) ? @product_line : nil
            CocoapodsPodx::Runtime.configure(project_directory: project_directory, product_line: product_line) if respond_to?(:project_directory)
            CocoapodsPodx::Runtime.config
          elsif config_file && File.exist?(config_file)
            pipeline_normalize_hash_keys(YAML.safe_load(File.read(config_file), permitted_classes: [], permitted_symbols: [], aliases: false) || {})
          else
            {}
          end
        rescue
          {}
        end
      end

      def pipeline_normalize_hash_keys(value)
        case value
        when Hash
          value.each_with_object({}) do |(key, nested_value), memo|
            memo[key.to_sym] = pipeline_normalize_hash_keys(nested_value)
          end
        when Array
          value.map { |item| pipeline_normalize_hash_keys(item) }
        else
          value
        end
      end

      def pipeline_report_markdown
        payload = pipeline_snapshot_payload
        sections = []
        sections << '# podx pipeline report'
        sections << ''
        sections << "- generated_at: #{payload[:generated_at]}"
        sections << "- status: #{payload[:status]}"
        sections << "- script: #{payload[:script_path]}"
        sections << "- snapshot: #{payload[:snapshot_path]}"
        sections << ''
        sections << '## Main Flow'
        sections << pipeline_markdown_table(%w[流程 顺序 动作 命令], pipeline_main_flow_rows)
        sections << ''
        sections << '## CI Steps'
        sections << pipeline_markdown_table(%w[顺序 阶段 命令 失败处理], pipeline_ci_rows)
        sections << ''
        sections << '## Doctor'
        sections << pipeline_markdown_table(%w[项目 状态 说明], pipeline_doctor_rows)
        sections << ''
        sections << '## Publish Policy'
        sections << pipeline_markdown_table(%w[渠道 门禁 分支规则 失败行为], pipeline_policy_rows)
        sections << ''
        sections << '## Publish Readiness'
        sections << pipeline_markdown_table(%w[渠道 门禁 准入 说明], pipeline_readiness_rows)
        sections << ''
        sections << '## Capability Map'
        sections << pipeline_markdown_table(%w[阶段 能力 命令 产物], pipeline_rows)
        sections << ''
        sections.join("\n")
      end

      def pipeline_snapshot_payload
        doctor_rows = pipeline_doctor_rows
        {
          generated_at: Time.now.utc.iso8601,
          status: doctor_rows.any? { |row| row[1] != '通过' } ? 'fail' : 'pass',
          script_path: pipeline_ci_script_path,
          snapshot_path: pipeline_snapshot_path,
          stages: pipeline_rows.map do |row|
            {
              phase: row[0],
              capability: row[1],
              command: row[2],
              artifact: row[3]
            }
          end,
          main_flows: pipeline_main_flow_rows.map do |row|
            {
              flow: row[0],
              order: row[1],
              action: row[2],
              command: row[3]
            }
          end,
          ci_steps: pipeline_ci_rows.map do |row|
            {
              order: row[0],
              stage: row[1],
              command: row[2],
              failure_action: row[3]
            }
          end,
          doctor: doctor_rows.map do |row|
            {
              item: row[0],
              status: row[1],
              detail: row[2]
            }
          end,
          policy: pipeline_policy_rows.map do |row|
            {
              channel: row[0],
              gate: row[1],
              branch_rule: row[2],
              failure_action: row[3]
            }
          end,
          readiness: pipeline_readiness_rows.map do |row|
            {
              channel: row[0],
              gate: row[1],
              readiness: row[2],
              detail: row[3]
            }
          end
        }
      end

      def pipeline_doctor_rows
        path = pipeline_ci_script_path
        exists = File.exist?(path)
        [
          ['脚本存在', exists ? '通过' : '失败', path],
          ['脚本可执行', exists && File.executable?(path) ? '通过' : '失败', path],
          ['脚本内容', exists && File.read(path) == pipeline_ci_script_content ? '通过' : '失败', '与当前 pipeline ci 模板一致']
        ]
      end

      def pipeline_ci_script_path
        File.join(project_directory, '.podx', 'pipeline_ci.sh')
      end

      def pipeline_snapshot_path
        File.join(project_directory, '.podx', 'pipeline_snapshot.json')
      end

      def pipeline_report_path
        File.join(project_directory, '.podx', 'pipeline_report.md')
      end

      def pipeline_markdown_table(headers, rows)
        lines = []
        lines << "| #{headers.join(' | ')} |"
        lines << "| #{headers.map { '---' }.join(' | ')} |"
        rows.each do |row|
          lines << "| #{row.map { |item| item.to_s.gsub('|', '\\|') }.join(' | ')} |"
        end
        lines.join("\n")
      end

      def pipeline_ci_script_content
        commands = pipeline_ci_rows.map do |row|
          stage = row[1]
          command = row[2]
          <<~SH
            echo "==> #{stage}: #{command}"
            #{command}
          SH
        end

        <<~SH
          #!/bin/sh
          set -e

          #{commands.join("\n")}
        SH
      end
    end
  end
end
