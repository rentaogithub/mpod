
module CocoapodsPodx
  module Commands
    module OverlayFile
      OVERLAY_PROJECT_FILE_NAME = 'Podfile.overlay'.freeze

      def load_entries
        return [] unless File.exist?(overlay_path)

        entries = []
        File.readlines(overlay_path, chomp: true).each do |line|
          entry = parse_overlay_entry(line)
          next unless entry

          entries.reject! { |item| item[:name] == entry[:name] }
          entries << entry
        end
        entries
      end

      def write_entries(entries)
        content_lines = if File.exist?(overlay_path)
          File.readlines(overlay_path, chomp: true)
        else
          default_overlay_lines
        end

        if @disable
          names_to_remove = @pod_names.to_set
          content_lines = content_lines.reject do |line|
            entry = parse_overlay_entry(line)
            entry && names_to_remove.include?(entry[:name])
          end
        else
          entry_by_name = entries.each_with_object({}) { |entry, memo| memo[entry[:name]] = entry }
          content_lines = ensure_overlay_separator(content_lines)
          @pod_names.each do |name|
            if entry_by_name.key?(name)
              next
            else
              content_lines << overlay_entry_line(name)
            end
          end
        end

        content_lines = normalize_overlay_spacing(content_lines)
        content_lines = trim_trailing_blank_lines(content_lines)
        content_lines << ''
        File.write(overlay_path, content_lines.join("\n"))
        add_overlay_file_to_xcodeproj
      end

      def create_overlay_file
        write_entries(load_entries)
        Pod::UI.puts "Podfile.overlay [ready] #{overlay_path}"
      end

      def preview_write_entries(entries)
        changed_count = 0

        if @disable
          names_to_remove = @pod_names.to_set
          existing_names = entries.map { |entry| entry[:name] }.to_set
          @pod_names.each do |name|
            next if existing_names.include?(name)

            Pod::UI.puts "#{name} [dry-run] overlay absent #{overlay_path}"
          end
          entries.each do |entry|
            next unless names_to_remove.include?(entry[:name])

            Pod::UI.puts "#{entry[:name]} [dry-run] overlay remove #{overlay_path}"
            changed_count += 1
          end
        else
          existing_names = entries.map { |entry| entry[:name] }.to_set
          @pod_names.each do |name|
            if existing_names.include?(name)
              Pod::UI.puts "#{name} [dry-run] overlay keep #{overlay_path}"
            else
              Pod::UI.puts "#{name} [dry-run] overlay add #{overlay_path}"
              changed_count += 1
            end
          end
        end

        Pod::UI.puts "Podfile.overlay [dry-run] #{changed_count}"
      end

      def default_overlay_lines
        [
          '# 本地源码覆盖配置',
          '# 这里只声明哪些组件切到本地源码。',
          '# 未出现在 Podfile.overlay 中的组件默认走远端。',
          '# 不要写 localWork、branch 或其他参数。',
          '# 示例：',
          "# pod 'AppFeatureKit'                    # 业务组件组切本地",
          "# pod 'AppBaseKit'               # 单个组件切本地",
          "# pod 'AppIMManager'                 # 单个组件切本地",
          "# pod 'AppAppearance'                 # 单个组件切本地",
          '',
          ''
        ]
      end

      def ensure_overlay_separator(lines)
        result = lines.dup
        while result.length > 1 && result[-1].empty? && result[-2].empty?
          result.pop
        end
        if result.any? { |line| line.match?(/^\s*pod\s+['"][^'"]+['"]/) }
          result.pop while result.any? && result.last.empty?
        elsif result.any? { |line| line.start_with?('# 示例：') }
          result << '' unless result.last.empty?
        else
          result << '' unless result.empty? || result.last.empty?
        end
        result
      end

      def normalize_overlay_spacing(lines)
        header_lines = []
        entry_lines = []

        lines.each do |line|
          entry = parse_overlay_entry(line)
          if entry
            entry_lines << overlay_entry_line(entry[:name])
          elsif entry_lines.empty?
            header_lines << line
          elsif !line.strip.empty? && !line.strip.start_with?('#')
            header_lines << line
          end
        end

        header_lines = trim_trailing_blank_lines(header_lines)
        return header_lines if entry_lines.empty?

        header_lines + [''] + entry_lines
      end

      def trim_trailing_blank_lines(lines)
        result = lines.dup
        result.pop while result.any? && result.last.empty?
        result
      end

      def parse_overlay_entry(line)
        pod_match = line.match(/^\s*(?:n)?pod\s+['"]([^'"]+)['"]\s*$/)
        return nil unless pod_match

        {
          name: pod_match[1]
        }
      end

      def overlay_entry_line(name)
        "pod '#{name}'"
      end

      def add_overlay_file_to_xcodeproj
        return unless respond_to?(:project_directory, true)

        project_path = overlay_xcodeproj_path
        return unless project_path

        begin
          require 'xcodeproj'
          project = Xcodeproj::Project.open(project_path)
          return if overlay_file_reference_exists?(project)

          project.main_group.new_file(overlay_project_file_name)
          project.save
          Pod::UI.puts "Podfile.overlay [xcodeproj] #{File.basename(project_path)}"
        rescue LoadError
          Pod::UI.puts 'Podfile.overlay [warn] 未安装 xcodeproj，无法自动加入 Xcode 工程'
        rescue => e
          Pod::UI.puts "Podfile.overlay [warn] 加入 Xcode 工程失败：#{e.message}"
        end
      end

      def overlay_xcodeproj_path
        explicit_workspace_project = Dir.glob(File.join(project_directory, '*.xcodeproj')).find do |path|
          File.basename(path) == 'AppIM.xcodeproj'
        end
        return explicit_workspace_project if explicit_workspace_project

        Dir.glob(File.join(project_directory, '*.xcodeproj')).sort.first
      end

      def overlay_file_reference_exists?(project)
        name = overlay_project_file_name
        project.files.any? do |file|
          file.path == name || file.display_name == File.basename(name)
        end
      end

      def overlay_project_file_name
        return OVERLAY_PROJECT_FILE_NAME unless respond_to?(:overlay_path, true)
        return OVERLAY_PROJECT_FILE_NAME unless respond_to?(:project_directory, true)

        path = File.expand_path(overlay_path)
        project_root = File.expand_path(project_directory)
        prefix = "#{project_root}/"
        path.start_with?(prefix) ? path.delete_prefix(prefix) : File.basename(path)
      rescue
        OVERLAY_PROJECT_FILE_NAME
      end

    end
  end
end
