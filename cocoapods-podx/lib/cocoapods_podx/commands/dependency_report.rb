require 'yaml'

module CocoapodsPodx
  module Commands
    module DependencyReport
      def show_dependency_report
        rows = build_dependency_report_rows
        print_box_table('主工程依赖', %w[组件 类型 分支/版本 依赖数], dependency_summary_rows(rows))
        relation_groups = dependency_relation_groups(rows)
        print_dependency_relation_table(relation_groups) unless relation_groups.empty?
        Pod::UI.puts "deps [done] #{rows.size}"
      end

      def dependency_summary_rows(rows)
        sorted_dependency_rows(rows).map do |name, type, version, dependencies|
          [
            name,
            type,
            version,
            dependency_list(dependencies).size.to_s
          ]
        end
      end

      def dependency_relation_rows(rows)
        dependency_relation_groups(rows).flat_map do |group|
          group[:lines].each_with_index.map do |line, index|
            [index.zero? ? group[:name] : '', line]
          end
        end
      end

      def dependency_relation_groups(rows)
        sorted_dependency_rows(rows).each_with_object([]) do |(name, _type, _version, dependencies), memo|
          deps = dependency_list(dependencies)
          next if deps.empty?

          memo << {
            name: name,
            lines: dependency_chunks(deps).map { |chunk| chunk.join(', ') }
          }
        end
      end

      def sorted_dependency_rows(rows)
        rows.each_with_index
          .sort_by { |(row, index)| [row[1] == '内部组件' ? 0 : 1, index] }
          .map(&:first)
      end

      def print_dependency_relation_table(groups)
        headers = %w[组件 依赖组件]
        display_rows = groups.flat_map do |group|
          group[:lines].each_with_index.map { |line, index| [index.zero? ? group[:name] : '', line] }
        end
        widths = headers.each_with_index.map do |header, index|
          ([dependency_display_width(header)] + display_rows.map { |row| dependency_display_width(row[index]) }).max
        end
        separator = "+#{widths.map { |width| '-' * (width + 2) }.join('+')}+"

        Pod::UI.puts '【组件依赖关系】'
        Pod::UI.puts separator
        Pod::UI.puts "| #{headers.each_with_index.map { |value, index| dependency_pad_display(value, widths[index]) }.join(' | ')} |"
        Pod::UI.puts separator
        groups.each_with_index do |group, group_index|
          Pod::UI.puts separator if group_index.positive?
          group[:lines].each_with_index do |line, line_index|
            name = line_index.zero? ? group[:name] : ''
            Pod::UI.puts "| #{dependency_pad_display(name, widths[0])} | #{dependency_pad_display(line, widths[1])} |"
          end
        end
        Pod::UI.puts separator
      end

      def dependency_pad_display(value, width)
        text = value.to_s
        text + (' ' * [width - dependency_display_width(text), 0].max)
      end

      def dependency_list(dependencies)
        dependencies.to_s.split(',').map(&:strip).reject { |item| item.empty? || item == '-' }
      end

      def dependency_chunks(dependencies, max_width = 72)
        chunks = []
        current = []
        current_width = 0

        dependencies.each do |dependency|
          dependency_width = dependency_display_width(dependency)
          separator_width = current.empty? ? 0 : 2
          if current.any? && current_width + separator_width + dependency_width > max_width
            chunks << current
            current = [dependency]
            current_width = dependency_width
          else
            current << dependency
            current_width += separator_width + dependency_width
          end
        end

        chunks << current if current.any?
        chunks
      end

      def dependency_display_width(value)
        value.to_s.each_char.sum { |char| char.ord > 127 ? 2 : 1 }
      end

      def build_dependency_report_rows
        lock = load_podfile_lock
        lock_versions, lock_dependencies = parse_lock_pods(lock['PODS'] || [])
        lock_direct_names = parse_lock_dependency_names(lock['DEPENDENCIES'] || [])
        podfile_specs = parse_podfile_direct_specs
        managed_specs = dependency_managed_specs

        names = []
        names.concat(lock_direct_names)
        names.concat(podfile_specs.keys)
        names.concat(managed_specs.keys)
        names.uniq.map do |name|
          raw_name = dependency_raw_name(name)
          managed = managed_specs[name] || managed_specs[raw_name]
          podfile_spec = podfile_specs[name] || podfile_specs[raw_name] || {}
          version = if managed
            managed[:branch] || podfile_spec[:branch] || '-'
          else
            lock_versions[name] || lock_versions[raw_name] || podfile_spec[:version] || podfile_spec[:branch] || '-'
          end
          deps = lock_dependencies[name] || lock_dependencies[raw_name] || []

          [
            name,
            managed ? '内部组件' : '三方库',
            version,
            deps.empty? ? '-' : deps.join(', ')
          ]
        end
      end

      def load_podfile_lock
        path = File.join(project_directory, 'Podfile.lock')
        return {} unless File.exist?(path)

        YAML.safe_load(File.read(path), permitted_classes: [Symbol], permitted_symbols: [], aliases: false) || {}
      rescue Psych::SyntaxError => e
        raise Pod::Informative, "Podfile.lock 解析失败：#{e.message}"
      end

      def parse_lock_pods(pods)
        versions = {}
        dependencies = {}

        Array(pods).each do |entry|
          case entry
          when String
            parsed = parse_locked_pod_name(entry)
            next unless parsed

            versions[parsed[:name]] ||= parsed[:version]
            versions[dependency_raw_name(parsed[:name])] ||= parsed[:version]
          when Hash
            entry.each do |key, values|
              parsed = parse_locked_pod_name(key.to_s)
              next unless parsed

              dep_names = Array(values).map { |value| parse_dependency_name(value.to_s) }.compact.uniq
              versions[parsed[:name]] ||= parsed[:version]
              versions[dependency_raw_name(parsed[:name])] ||= parsed[:version]
              dependencies[parsed[:name]] = dep_names
              dependencies[dependency_raw_name(parsed[:name])] ||= dep_names
            end
          end
        end

        [versions, dependencies]
      end

      def parse_lock_dependency_names(dependencies)
        Array(dependencies).map { |value| parse_dependency_name(value.to_s) }.compact.uniq
      end

      def parse_locked_pod_name(value)
        match = value.match(/\A\s*([^()]+?)\s+\(([^)]+)\)/)
        return nil unless match

        {
          name: match[1].strip,
          version: match[2].strip
        }
      end

      def parse_dependency_name(value)
        name = value.sub(/\s+\(.+\)\s*\z/, '').strip
        name.empty? ? nil : name
      end

      def parse_podfile_direct_specs
        path = File.join(project_directory, 'Podfile')
        return {} unless File.exist?(path)

        specs = {}
        File.readlines(path, chomp: true).each do |line|
          parsed = parse_podfile_pod_line(line)
          next unless parsed

          specs[parsed[:name]] = parsed
          specs[dependency_raw_name(parsed[:name])] ||= parsed
        end
        specs
      end

      def parse_podfile_pod_line(line)
        match = line.match(/^\s*(?:n?pod)\s+['"]([^'"]+)['"]\s*(?:,\s*(.*))?$/)
        return nil unless match

        option_source = match[2].to_s
        {
          name: match[1],
          version: extract_podfile_literal_version(option_source),
          branch: extract_podfile_branch(option_source)
        }.compact
      end

      def extract_podfile_literal_version(source)
        match = source.match(/\A\s*['"]([^'"]+)['"]/)
        match && match[1]
      end

      def extract_podfile_branch(source)
        match = source.match(/(?:branch\s*:|:branch\s*=>)\s*['"]([^'"]+)['"]/)
        match && match[1]
      end

      def dependency_managed_specs
        specs = {}
        CocoapodsPodx::Runtime.managed_pod_entries.each do |definition|
          name = definition[:name]
          branch = definition[:branch]
          group_name = definition[:group_name]
          specs[name] = { branch: branch }
          specs[dependency_raw_name(name)] ||= { branch: branch }
          specs[group_name] ||= { branch: branch } if group_name && group_name != 'app_ios'
        end
        specs
      end

      def dependency_raw_name(name)
        name.to_s.split('/').first
      end
    end
  end
end
