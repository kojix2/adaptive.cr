require "yaml"
require "json"
require "file_utils"
require "file/tempfile"

module NanoporeGUI
  # English source messages are stable catalogue keys. Embed every catalogue so
  # packaged applications do not depend on the current working directory.
  module Translations
    SUPPORTED_LOCALES = {"en", "es", "fr", "de", "zh", "ja"}
    LOCALE_NAMES      = {"English", "Español", "Français", "Deutsch", "简体中文", "日本語"}
    CATALOGUES        = {
      "en" => YAML.parse({{ read_file("#{__DIR__}/../../config/locales/en.yml") }}).as_h,
      "es" => YAML.parse({{ read_file("#{__DIR__}/../../config/locales/es.yml") }}).as_h,
      "fr" => YAML.parse({{ read_file("#{__DIR__}/../../config/locales/fr.yml") }}).as_h,
      "de" => YAML.parse({{ read_file("#{__DIR__}/../../config/locales/de.yml") }}).as_h,
      "zh" => YAML.parse({{ read_file("#{__DIR__}/../../config/locales/zh.yml") }}).as_h,
      "ja" => YAML.parse({{ read_file("#{__DIR__}/../../config/locales/ja.yml") }}).as_h,
    }
    @@locale : String? = nil
    @@preference : String? = nil

    def self.setup(requested_locale : String? = nil) : String
      @@preference = (requested_locale || saved_locale).try { |value| resolve_locale(value) }
      @@locale = resolve_locale(@@preference)
    end

    def self.locale : String
      @@locale || setup
    end

    def self.preference : String?
      locale
      @@preference
    end

    def self.t(message : String, **values) : String
      key = YAML::Any.new(message)
      translated = (CATALOGUES[locale][key]? || CATALOGUES["en"][key]?).try(&.as_s) || message
      # One pass prevents placeholder-like text in paths and error messages from
      # being interpreted as another interpolation parameter.
      translated.gsub(/%\{([^}]+)\}/) do |placeholder|
        name = placeholder[2...-1]
        values.to_a.find { |pair| pair[0].to_s == name }.try(&.[1].to_s) || placeholder
      end
    end

    # Child-process diagnostics remain verbatim; translate the surrounding UI.
    def self.display_status(value : String) : String
      case value
      when /^Finished \((.*)\)$/     then t("Finished (%{result})", result: $1)
      when /^Process error: (.*)$/   then t("Process error: %{error}", error: $1)
      when /^Could not start: (.*)$/ then t("Could not start: %{error}", error: $1)
      else                                t(value)
      end
    end

    def self.preference_path : String
      base = ENV["XDG_CONFIG_HOME"]?.presence || File.join(Path.home.to_s, ".config")
      File.join(base, "adaptive", "gui.json")
    end

    def self.saved_locale(path : String = preference_path) : String?
      value = JSON.parse(File.read(path)).as_h?.try(&.["locale"]?).try(&.as_s?)
      value if SUPPORTED_LOCALES.includes?(value)
    rescue IO::Error | JSON::ParseException | TypeCastError
      nil
    end

    # Language changes are applied on the next launch, as in d4-plot. Saving
    # these preferences never writes to a simulation or acquisition config.
    def self.save_locale(value : String?, path : String = preference_path) : Nil
      raise ArgumentError.new("Unsupported locale: #{value}") if value && !SUPPORTED_LOCALES.includes?(value)
      FileUtils.mkdir_p(File.dirname(path))
      temporary = File.tempfile("gui-", ".json", dir: File.dirname(path))
      begin
        temporary << {locale: value}.to_json << "\n"
        temporary.close
        File.rename(temporary.path, path)
        @@preference = value
      ensure
        temporary.close
        File.delete?(temporary.path)
      end
    end

    def self.resolve_locale(requested_locale : String? = nil) : String
      value = requested_locale || system_locale || "en"
      language = value.downcase.split(/[_.@:-]/, 2).first
      SUPPORTED_LOCALES.includes?(language) ? language : "en"
    end

    private def self.system_locale : String?
      environment = {"LC_ALL", "LC_MESSAGES", "LANGUAGE", "LANG"}.compact_map { |key| ENV[key]?.presence }.first?
      {% if flag?(:darwin) || flag?(:win32) %}
        native_system_locale || environment
      {% else %}
        environment
      {% end %}
    end

    {% if flag?(:darwin) %}
      @[Link(framework: "CoreFoundation")]
      lib CoreFoundation
        fun CFLocaleCopyPreferredLanguages : Void*
        fun CFArrayGetCount(array : Void*) : Int64
        fun CFArrayGetValueAtIndex(array : Void*, index : Int64) : Void*
        fun CFStringGetCString(string : Void*, buffer : UInt8*, buffer_size : Int64, encoding : UInt32) : UInt8
        fun CFRelease(object : Void*)
      end

      private def self.native_system_locale : String?
        languages = CoreFoundation.CFLocaleCopyPreferredLanguages
        return nil if languages.null?
        begin
          return nil if CoreFoundation.CFArrayGetCount(languages) == 0
          value = CoreFoundation.CFArrayGetValueAtIndex(languages, 0)
          buffer = Bytes.new(256)
          if CoreFoundation.CFStringGetCString(value, buffer.to_unsafe, buffer.size, 0x08000100_u32) != 0
            String.new(buffer.to_unsafe)
          end
        ensure
          CoreFoundation.CFRelease(languages)
        end
      end
    {% elsif flag?(:win32) %}
      @[Link("kernel32")]
      lib Kernel32
        fun GetUserDefaultLocaleName(locale_name : UInt16*, locale_name_count : Int32) : Int32
      end

      private def self.native_system_locale : String?
        buffer = Slice(UInt16).new(85, 0_u16)
        length = Kernel32.GetUserDefaultLocaleName(buffer.to_unsafe, buffer.size)
        length > 1 ? String.from_utf16(buffer[0, length - 1]) : nil
      end
    {% else %}
      private def self.native_system_locale : String?
        nil
      end
    {% end %}
  end

  def self.t(message : String, **values) : String
    Translations.t(message, **values)
  end
end
