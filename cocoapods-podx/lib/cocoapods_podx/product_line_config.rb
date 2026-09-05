module CocoapodsPodx
  module ProductLineConfig
    STRUCTURAL_KEYS = %i[
      default_product_line
      default_line
      active_product_line
      product_line
      shared
      product_lines
      platform
    ].freeze

    class << self
      def resolve(raw_config, requested_line = nil)
        raw = raw_config.is_a?(Hash) ? raw_config : {}
        line_id = selected_line(raw, requested_line)
        legacy = legacy_config(raw)
        line_config = line_id ? product_line_config(raw[:product_lines], line_id) : {}
        if line_id && raw[:product_lines] && line_config.empty?
          raise "未找到产品线配置：#{line_id}"
        end
        effective = deep_merge(legacy, normalize_hash(raw[:shared]))
        effective = deep_merge(effective, line_config)
        effective[:product_line_id] ||= line_id if line_id
        effective[:product_line_key] ||= line_config[:key] if line_config[:key]
        normalize_platform_export!(effective)
        flatten_nested_config!(effective)
        effective
      end

      def selected_line(raw_config, requested_line = nil)
        requested = requested_line.to_s.strip
        requested = ENV['PODX_PRODUCT_LINE'].to_s.strip if requested.empty?
        requested = ENV['COCOAPODS_PODX_PRODUCT_LINE'].to_s.strip if requested.empty?
        requested = raw_config[:active_product_line].to_s.strip if requested.empty?
        requested = raw_config[:product_line].to_s.strip if requested.empty?
        requested = raw_config[:default_product_line].to_s.strip if requested.empty?
        requested = raw_config[:default_line].to_s.strip if requested.empty?
        requested.empty? ? nil : requested
      end

      private

      def legacy_config(raw)
        raw.reject { |key, _| STRUCTURAL_KEYS.include?(key) }
      end

      def product_line_config(lines, line_id)
        case lines
        when Hash
          direct = lines[line_id.to_sym] || lines[line_id.to_s]
          return normalize_hash(direct).merge(product_line_id: line_id) if direct

          matched = lines.values.find do |item|
            normalized = normalize_hash(item)
            [normalized[:id], normalized[:key], normalized[:project_id]].map(&:to_s).include?(line_id.to_s)
          end
          return {} unless matched

          normalize_hash(matched).merge(product_line_id: line_id)
        when Array
          matched = lines.find do |item|
            normalized = normalize_hash(item)
            [normalized[:id], normalized[:key], normalized[:project_id]].map(&:to_s).include?(line_id.to_s)
          end
          return {} unless matched

          normalize_hash(matched).merge(product_line_id: line_id)
        else
          {}
        end
      end

      def normalize_hash(value)
        value.is_a?(Hash) ? value : {}
      end

      def deep_merge(left, right)
        result = normalize_hash(left).dup
        normalize_hash(right).each do |key, value|
          result[key] = if result[key].is_a?(Hash) && value.is_a?(Hash)
            deep_merge(result[key], value)
          else
            value
          end
        end
        result
      end

      def normalize_platform_export!(config)
        assign_first_present!(config, :target_name, :PODX_TARGET_NAME, :podx_target_name)
        assign_first_present!(config, :private_source, :PODX_PRIVATE_SOURCE, :podx_private_source)
        assign_first_present!(config, :git_base_url, :PODX_GIT_BASE_URL, :podx_git_base_url)
        assign_first_present!(config, :overlay_file, :PODX_OVERLAY_FILE, :podx_overlay_file)
        assign_first_present!(config, :publish_work_dir, :PODX_PUBLISH_WORK_DIR, :podx_publish_work_dir)
        assign_first_present!(config, :publish_base_branch, :PODX_PUBLISH_BASE_BRANCH, :podx_publish_base_branch)
        assign_first_present!(config, :publish_main_repo, :PODX_PUBLISH_MAIN_REPO, :podx_publish_main_repo)
        assign_first_present!(config, :publish_repos, :PODX_PUBLISH_REPOS, :podx_publish_repos)
        assign_first_present!(config, :jenkins_base_url, :JENKINS_BASE_URL, :jenkins_base_url)
        assign_first_present!(config, :jenkins_job, :JENKINS_NN_JOB, :jenkins_nn_job)
        assign_first_present!(config, :jenkins_quality_job, :JENKINS_NN_QA_JOB, :jenkins_nn_qa_job)
        assign_first_present!(config, :jenkins_repo_url, :JENKINS_NN_REPO_URL, :jenkins_nn_repo_url)
      end

      def flatten_nested_config!(config)
        publish = normalize_hash(config[:publish])
        config[:publish_work_dir] = publish[:work_dir] if publish.key?(:work_dir)
        config[:publish_base_branch] = publish[:base_branch] if publish.key?(:base_branch)
        config[:publish_main_repo] = publish[:main_repo] if publish.key?(:main_repo)
        config[:publish_update_podfile_branch] = publish[:update_podfile_branch] if publish.key?(:update_podfile_branch)
        config[:publish_pipeline_gate] = publish[:pipeline_gate] if publish.key?(:pipeline_gate)
        config[:publish_pipeline_gate_strategy] = publish[:pipeline_gate_strategy] if publish.key?(:pipeline_gate_strategy)
        config[:publish_repos] = normalize_repo_list(publish[:repos]) if publish.key?(:repos)
        config[:publish_repos] = normalize_repo_list(config[:publish_repos])
        config[:publish_version] = publish[:version] if publish.key?(:version)

        jenkins = normalize_hash(config[:jenkins])
        config[:jenkins_base_url] = jenkins[:base_url] if jenkins.key?(:base_url)
        config[:jenkins_job] = jenkins[:job] || jenkins[:default_job] || jenkins[:build_job] if jenkins.key?(:job) || jenkins.key?(:default_job) || jenkins.key?(:build_job)
        config[:jenkins_quality_job] = jenkins[:quality_job] if jenkins.key?(:quality_job)
        config[:jenkins_repo_url] = jenkins[:repo_url] if jenkins.key?(:repo_url)
      end

      def normalize_repo_list(value)
        case value
        when String
          value.split(/[\n,]/).map(&:strip).reject(&:empty?)
        when Array
          value
        else
          value
        end
      end

      def assign_first_present!(config, target, *sources)
        return if present?(config[target])

        sources.each do |source|
          next unless present?(config[source])

          config[target] = config[source]
          return
        end
      end

      def present?(value)
        !value.nil? && !value.to_s.strip.empty?
      end
    end
  end
end
