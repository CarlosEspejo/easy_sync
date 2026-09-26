# frozen_string_literal: true

module EasySync
  module Jbod
    # What a share's top level holds, by the one rule `sync` uses to decide
    # its units: each visible, non-excluded subfolder is one unit; visible,
    # non-excluded loose files together are one more.
    module ShareScan
      module_function

      def subfolders(path, excludes)
        entries(path, excludes).select { |n| File.directory?(File.join(path, n)) }
      end

      def loose_files(path, excludes)
        entries(path, excludes).select { |n| File.file?(File.join(path, n)) }
      end

      def entries(path, excludes)
        Dir.children(path).sort.reject do |n|
          n.start_with?('.') || Array(excludes).any? { |pat| File.fnmatch?(pat, n) }
        end
      end
    end
  end
end
