# frozen_string_literal: true

require "digest"
require "rbconfig"

module Ghwatch
  # Notices a newly installed ghwatch (e.g. `rake install:user`) so the
  # running one can restart into it at a point where no agent runs. Only an
  # installed gem restarts itself; a checkout run from source does not, so
  # editing files there never restarts it.
  class SelfUpdate
    LIB_ROOT = File.expand_path("..", __dir__)

    def self.installed_gem?(root = LIB_ROOT)
      Gem.path.any? { |path| root.start_with?(File.join(File.expand_path(path), "gems") + File::SEPARATOR) }
    end

    def initialize(root: LIB_ROOT, enabled: self.class.installed_gem?, settle: 5, sleeper: ->(seconds) { sleep(seconds) })
      @root = root
      @enabled = enabled
      @settle = settle
      @sleeper = sleeper
      @stamp = stamp if enabled
    end

    def enabled? = @enabled

    # True once the files differ from those ghwatch started with and have
    # stopped changing, so an installation still in progress is not loaded.
    def updated?
      return false unless @enabled

      current = stamp
      return false if current == @stamp

      @sleeper.call(@settle)
      current == stamp
    end

    def stamp
      files = Dir.glob(File.join(@root, "**", "*")).select { |path| File.file?(path) }.sort
      Digest::SHA256.hexdigest(files.map { |path| [path, File.mtime(path).to_f, File.size(path)].join("\0") }.join("\n"))
    end

    # Replaces this process with a fresh ghwatch with the same arguments.
    def restart(argv)
      exec(RbConfig.ruby, $PROGRAM_NAME, *argv)
    end
  end
end
