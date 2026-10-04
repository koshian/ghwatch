# frozen_string_literal: true

require_relative "test_helper"
require "pathname"
require "ostruct"

class GithubLanguageTest < Minitest::Test
  def config(language = "auto")
    Ghwatch::Config.new({"github" => {"human_language" => language}})
  end

  def test_explicit_language_overrides_the_environment
    assert_equal "Japanese", config("Japanese").human_language(environment: {"LC_ALL" => "en_US.UTF-8"})
    assert_equal "ja", config("ja").human_language(environment: {})
  end

  def test_omitted_setting_uses_the_environment
    assert_equal "ja-JP", Ghwatch::Config.new({}).human_language(environment: {"LANG" => "ja_JP.UTF-8"})
  end

  def test_each_locale_variable_is_supported
    %w[LC_ALL LANGUAGE LC_MESSAGES LANG].each do |name|
      assert_equal "ja-JP", config.human_language(environment: {name => "ja_JP.UTF-8"})
    end
  end

  def test_locale_precedence
    environment = {"LC_ALL" => "de_DE", "LANGUAGE" => "ja:en", "LC_MESSAGES" => "fr_FR", "LANG" => "en_US"}
    %w[de-DE ja fr-FR en-US].each_with_index do |expected, index|
      assert_equal expected, config.human_language(environment: environment)
      environment.delete(%w[LC_ALL LANGUAGE LC_MESSAGES LANG][index])
    end
  end

  def test_language_preferences_and_locale_variants
    assert_equal "ja", config.human_language(environment: {"LANGUAGE" => "invalid:ja:en"})
    assert_equal "sr-RS", config.human_language(environment: {"LANG" => "sr_RS.UTF-8@latin"})
    assert_equal "zh-Hant-TW", config.human_language(environment: {"LANG" => "zh-Hant-TW"})
    assert_equal "fr-FR", config.human_language(environment: {"LC_ALL" => "", "LANG" => "fr_FR"})
  end

  def test_c_posix_and_unknown_environments_use_english
    %w[C C.UTF-8 POSIX].each do |locale|
      assert_equal "en", config.human_language(environment: {"LC_ALL" => locale, "LANG" => "ja_JP"})
    end
    assert_equal "en", config.human_language(environment: {})
    assert_equal "en", config.human_language(environment: {"LANG" => "unrecognized"})
  end

  def test_invalid_language_setting_is_rejected
    [nil, "", "  ", 123].each do |language|
      assert_raises(Ghwatch::Config::Error) { config(language) }
    end
  end

  def test_all_roles_receive_the_language_instruction_even_with_a_prompt_override
    Dir.mktmpdir do |directory|
      roles = %w[triage worker reviewer deep_reviewer finalizer]
      data = {"github" => {"human_language" => "ja"}, "roles" => roles.to_h do |role|
        [role, {"models" => [{"runner" => "test", "model" => "test"}]}]
      end}
      File.write(File.join(directory, "reviewer.md"), "Write your review in English.")
      store = Ghwatch::PromptStore.new(
        project: OpenStruct.new(prompt_dir: Pathname.new(directory)), config: Ghwatch::Config.new(data)
      )
      roles.each do |role|
        prompt = store.compose(role, context: "Current discussion is in English.")
        assert_includes prompt, "Write all human-facing GitHub text in ja"
        assert_includes prompt, "protocol status values unchanged"
        assert_includes prompt, Ghwatch::Result.contract_for(role)
      end
    end
  end
end
