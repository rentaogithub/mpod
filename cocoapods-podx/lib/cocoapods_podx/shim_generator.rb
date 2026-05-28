module CocoapodsPodx
  module ShimGenerator
    class << self
      def podx
        content('podx')
      end

      def mgit
        content('mgit')
      end

      def content(name)
        path = File.expand_path("shims/#{name}", __dir__)
        path = File.expand_path("../../bin/#{name}", __dir__) unless File.exist?(path)
        raise "未找到 #{name} shim 模板：#{path}" unless File.exist?(path)

        File.read(path)
      end
    end
  end
end
