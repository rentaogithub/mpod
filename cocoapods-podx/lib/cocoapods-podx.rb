require 'cocoapods'
require_relative 'cocoapods_podx/runtime'
require_relative 'cocoapods_podx/shim_generator'
require_relative 'pod/command/podx'

module CocoapodsPodx
  module DSLPatch
    def pod(name = nil, *requirements)
      has_options = requirements.last.is_a?(Hash)
      explicit_options = has_options ? requirements.pop.dup : {}

      unless CocoapodsPodx::Runtime.managed_options?(explicit_options) || CocoapodsPodx::Runtime.managed_pod?(name)
        requirements << explicit_options if has_options
        return super(name, *requirements)
      end

      clean_options = CocoapodsPodx::Runtime.strip_managed_options(explicit_options)
      merged_options = CocoapodsPodx::Runtime.pod_options_for(name: name, explicit_options: explicit_options)
      merged_options = merged_options.merge(clean_options)
      requirements << merged_options
      super(name, *requirements)
    end

    def npod(name = nil, *requirements)
      pod(name, *requirements)
    end
  end
end

Pod::Podfile::DSL.prepend(CocoapodsPodx::DSLPatch)
