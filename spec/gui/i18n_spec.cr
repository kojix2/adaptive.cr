require "spec"
require "../../src/gui/i18n"
require "../../src/gui/profile"

NanoporeGUI::Translations.setup("en")

describe NanoporeGUI::Translations do
  it "normalizes regional locales and falls back to English" do
    {"en_US.UTF-8" => "en", "es-ES" => "es", "fr_FR@euro" => "fr", "de:en" => "de", "zh-Hans-CN" => "zh", "ja_JP.UTF-8" => "ja", "C" => "en", "xx-XX" => "en"}.each do |input, expected|
      NanoporeGUI::Translations.resolve_locale(input).should eq(expected)
    end
  end

  it "embeds complete catalogues with matching interpolation parameters" do
    catalogues = NanoporeGUI::Translations::CATALOGUES
    english = catalogues["en"]
    NanoporeGUI::Translations::SUPPORTED_LOCALES.each do |locale|
      catalogue = catalogues[locale]
      catalogue.keys.map(&.as_s).sort!.should eq(english.keys.map(&.as_s).sort!)
      english.each do |key, value|
        translated = catalogue[key].as_s
        translated.should_not be_empty
        translated.scan(/%\{([^}]+)\}/).map(&.[1]).sort!.should eq(value.as_s.scan(/%\{([^}]+)\}/).map(&.[1]).sort!), "#{locale}: #{key}"
      end
    end
  end

  it "translates all six languages independently of the working directory" do
    expected = ["Start", "Iniciar", "Démarrer", "Starten", "开始", "開始"]
    Dir.cd(Dir.tempdir) do
      NanoporeGUI::Translations::SUPPORTED_LOCALES.each_with_index do |locale, index|
        NanoporeGUI::Translations.setup(locale)
        NanoporeGUI.t("Start").should eq(expected[index])
        NanoporeGUI.t("An external diagnostic").should eq("An external diagnostic")
      end
    end
  ensure
    NanoporeGUI::Translations.setup("en")
  end

  it "interpolates values once without changing user data" do
    NanoporeGUI::Translations.setup("ja")
    NanoporeGUI.t("Working directory does not exist: %{path}", path: "file-%{other}-é.fa").should contain("file-%{other}-é.fa")
  ensure
    NanoporeGUI::Translations.setup("en")
  end

  it "persists a language separately and can return to the system default" do
    file = File.tempfile("gui-preferences-", ".json")
    path = file.path
    file.close
    NanoporeGUI::Translations.setup("en")
    NanoporeGUI::Translations.save_locale("fr", path)
    NanoporeGUI::Translations.saved_locale(path).should eq("fr")
    NanoporeGUI::Translations.locale.should eq("en")
    NanoporeGUI::Translations.save_locale(nil, path)
    NanoporeGUI::Translations.saved_locale(path).should be_nil
    expect_raises(ArgumentError) { NanoporeGUI::Translations.save_locale("xx", path) }
    ["invalid json", "[]", "null", %({"locale":42}), %({"locale":"xx"})].each do |invalid|
      File.write(path, invalid)
      NanoporeGUI::Translations.saved_locale(path).should be_nil
    end
  ensure
    file.try(&.close)
    File.delete?(path) if path
    NanoporeGUI::Translations.setup("en")
  end

  it "gives a command-line locale priority over a saved preference" do
    previous = ENV["XDG_CONFIG_HOME"]?
    directory = File.tempname("gui-config-")
    ENV["XDG_CONFIG_HOME"] = directory
    NanoporeGUI::Translations.save_locale("de")
    NanoporeGUI::Translations.setup.should eq("de")
    NanoporeGUI::Translations.setup("ja-JP").should eq("ja")
    NanoporeGUI::Translations.save_locale(nil)
    NanoporeGUI::Translations.saved_locale.should be_nil
  ensure
    if previous
      ENV["XDG_CONFIG_HOME"] = previous
    else
      ENV.delete("XDG_CONFIG_HOME")
    end
    FileUtils.rm_rf(directory) if directory
    NanoporeGUI::Translations.setup("en")
  end
end

describe "Translated form captions" do
  it "includes every profile field and mode in the catalogues" do
    english = NanoporeGUI::Translations::CATALOGUES["en"]
    (NanoporeGUI::Profile.fields.map(&.label) + NanoporeGUI::Profile.modes).each do |message|
      english.has_key?(YAML::Any.new(message)).should be_true, message
    end
  end
end
