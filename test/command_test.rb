# frozen_string_literal: true

require_relative "test_helper"
require "stringio"

class CommandTest < Minitest::Test
  def test_child_pwd_matches_its_working_directory
    Dir.mktmpdir("ghwatch-command") do |directory|
      command = Ghwatch::Command.new(log: Ghwatch::Log.new(StringIO.new))
      result = command.run("sh", "-c", 'printf "%s" "$PWD"', chdir: directory)
      assert_equal File.expand_path(directory), result.stdout
    end
  end
end
