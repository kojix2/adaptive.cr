require "uing"
require "./i18n"

module NanoporeGUI
  class LanguagePicker
    getter view = UIng::Box.new(:horizontal, padded: true)
    getter choices = UIng::Combobox.new

    def initialize(window : UIng::Window)
      @view.append(UIng::Label.new(NanoporeGUI.t("Language")))
      @choices.append(NanoporeGUI.t("System language"))
      Translations::LOCALE_NAMES.each { |name| @choices.append(name) }
      @choices.selected = Translations.preference.try { |value| Translations::SUPPORTED_LOCALES.index(value).try(&.+(1)) } || 0
      @view.append(@choices)
      @view.append(UIng::Label.new(NanoporeGUI.t("Language changes apply after restarting.")))
      @choices.on_selected do |index|
        previous = Translations.preference
        begin
          Translations.save_locale(index == 0 ? nil : Translations::SUPPORTED_LOCALES[index - 1])
        rescue error
          @choices.selected = previous.try { |value| Translations::SUPPORTED_LOCALES.index(value).try(&.+(1)) } || 0
          window.msg_box_error(NanoporeGUI.t("Language"), error.message || error.to_s)
        end
        nil
      end
    end
  end
end
