require 'fileutils'
require 'json'

module CocoapodsPodx
  class FailureCaseStore
    def self.default
      new(ENV['COCOAPODS_PODX_FAILURE_CASE_DB'])
    end

    attr_reader :path

    def initialize(path = nil)
      @path = normalize_path(path)
    end

    def disabled?
      path.empty?
    end

    def append(record)
      return if disabled?

      FileUtils.mkdir_p(File.dirname(path))
      File.open(path, 'a') { |file| file.puts(JSON.generate(record)) }
      record
    end

    def recent_summaries(current_fingerprint: nil, limit: 5, formatter:)
      return [] if disabled? || !File.exist?(path)

      records.reverse.filter_map do |record|
        next if current_fingerprint && record[:fingerprint].to_s == current_fingerprint.to_s

        formatter.call(record)
      end.first(limit)
    end

    private

    def normalize_path(value)
      return '' if value.to_s == '0'
      return File.expand_path(value) unless value.nil? || value.to_s.strip.empty?

      File.expand_path('~/.cocoapods-podx/jenkins_failure_cases.jsonl')
    end

    def records
      File.readlines(path).last(100).filter_map do |line|
        JSON.parse(line, symbolize_names: true)
      rescue JSON::ParserError
        nil
      end
    end
  end
end
