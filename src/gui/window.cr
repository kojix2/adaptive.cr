require "uing/crimage"
require "icon-radix"
require "./model"
require "./runner"
require "./profile"

module NanoporeGUI
  class Window
    getter runner = Runner.new
    getter window : UIng::Window
    getter editor = UIng::MultilineEntry.new(false)
    getter tabs = UIng::Tab.new
    getter directory = UIng::Entry.new
    getter replay : UIng::Entry?
    getter mode : UIng::Combobox
    getter document : Document
    @entries = {} of String => UIng::Entry
    @original_text = {} of String => String
    @checks = {} of String => UIng::Checkbox
    @editable = [] of UIng::Control
    @log_view = UIng::MultilineEntry.new(false, true)
    @status = UIng::Label.new("Ready")
    @file = UIng::Label.new("Unsaved configuration")
    getter toolbar = UIng::Toolbar.new
    getter actions = {} of Symbol => UIng::ToolbarItem
    @path : String?
    @last_tab = 0
    @switching = false
    @was_busy = false
    @closing = false
    @closed = false
    @log_generation = 0_u64
    @next_log_update = Time.instant
    @last_status = "Ready"

    def initialize(@executable : String, working_directory : String)
      @document = Profile.initial
      @window = UIng::Window.new(Profile.title, 880, 700, margined: true)
      @mode = UIng::Combobox.new(Profile.modes)
      @replay = Profile.replay? ? UIng::Entry.new : nil
      @mode.selected = 0
      @directory.text = working_directory
      root = UIng::Box.new(:vertical, padded: true)
      root.append(@file)
      root.append(directory_row)
      root.append(build_tabs, stretchy: true)
      root.append(run_options)
      root.append(@status)
      @window.child = root
      @window.toolbar = build_toolbar
      @window.on_closing { request_close; false }
      UIng.on_should_quit { request_close; false }
      @actions[:stop].disable
      fill_fields
      @tabs.on_selected { |index| switch_tab(index); nil }
    end

    def show
      @window.show
    end

    def closed? : Bool
      @closed
    end

    # UI updates stay on the native main thread. The stepped event loop yields
    # to Crystal's nonblocking process/pipe fibers between native events.
    def pump
      busy = @runner.busy?
      if busy != @was_busy
        set_busy(busy)
        @was_busy = busy
      end
      if @log_generation != @runner.log.generation && Time.instant >= @next_log_update
        @log_view.text = @runner.log.text
        @log_generation = @runner.log.generation
        @next_log_update = Time.instant + 100.milliseconds
      end
      if @last_status != @runner.status
        @last_status = @runner.status
        @status.text = @last_status
      end
      if @closing && !busy && !@closed
        @window.destroy
        @closed = true
        UIng.quit
      end
    end

    def request_close
      @closing = true
      @runner.stop if @runner.busy?
    end

    def load_config(path : String)
      document = Profile.parse(File.read(path))
      @document = document
      @path = File.expand_path(path)
      fill_fields
      @editor.text = @document.text
      @file.text = File.expand_path(path)
    end

    def save_config(path : String)
      synchronize_document
      File.write(path, @document.text + "\n")
      @path = File.expand_path(path)
      @file.text = File.expand_path(path)
    end

    def launch(action : Symbol = :run)
      synchronize_document
      args = Profile.arguments(action, @mode.selected || 0, @replay.try(&.text) || "")
      @runner.start(@executable, args, @document.text, File.expand_path(@directory.text || ""))
      @log_generation = 0_u64
      @log_view.text = ""
      @tabs.selected = 2
      @last_tab = 2
      set_busy(true)
      @was_busy = true
    end

    private def guarded(&)
      yield
    rescue error
      @window.msg_box_error(Profile.title, error.message || error.to_s)
    end

    private def button(label : String, parent : UIng::Box, &block : ->)
      control = UIng::Button.new(label)
      control.on_clicked { guarded { block.call }; nil }
      parent.append(control)
      @editable << control
      control
    end

    private def toolbar_button(action : Symbol, label : String, icon : CrImage::Image, &block : ->)
      item = @toolbar.append_button(label, icon)
      item.tooltip = label
      item.on_clicked { guarded { block.call }; nil }
      @actions[action] = item
      item
    end

    private def build_toolbar
      @toolbar.display_mode = UIng::Toolbar::DisplayMode::IconAndTextVertical
      toolbar_button(:new, "New", Icon::Radix::FilePlus) do
        @document = Profile.initial
        @path = nil
        fill_fields
        @editor.text = @document.text
        @file.text = "Unsaved configuration"
      end
      toolbar_button(:open, "Open…", Icon::Radix::OpenInNewWindow) do
        if path = @window.open_file
          load_config(path)
        end
      end
      toolbar_button(:save, "Save", Icon::Radix::Download) do
        if path = @path || @window.save_file
          save_config(path)
        end
      end
      toolbar_button(:save_as, "Save as…", Icon::Radix::Copy) do
        if path = @window.save_file
          save_config(path)
        end
      end
      @toolbar.append_separator
      toolbar_button(:settings, "Settings", Icon::Radix::Gear) { select_tab(0) }
      toolbar_button(:validate, "Validate", Icon::Radix::CheckCircled) { launch(:validate) }
      if Profile.replay?
        toolbar_button(:backend, "Check basecaller", Icon::Radix::LightningBolt) { launch(:backend) }
      end
      @toolbar.append_separator
      toolbar_button(:start, "Start", Icon::Radix::Play) { launch }
      toolbar_button(:stop, "Stop", Icon::Radix::Stop) { @runner.stop }
      @toolbar
    end

    private def directory_row
      row = UIng::Box.new(:horizontal, padded: true)
      row.append(UIng::Label.new("Working directory"))
      row.append(@directory, stretchy: true)
      @editable << @directory
      button("Browse…", row) do
        if path = @window.open_folder
          @directory.text = path
        end
      end
      row
    end

    private def build_tabs
      form = UIng::Form.new(padded: true)
      Profile.fields.each do |field|
        if field.kind == :bool
          check = UIng::Checkbox.new(field.label)
          @checks[field.key] = check
          form.append("", check)
        else
          entry = UIng::Entry.new
          @entries[field.key] = entry
          if field.picker
            row = UIng::Box.new(:horizontal, padded: true)
            row.append(entry, stretchy: true)
            button("Browse…", row) do
              path = field.picker == :save ? @window.save_file : @window.open_file
              entry.text = path if path
            end
            form.append(field.label, row)
          else
            form.append(field.label, entry)
          end
        end
      end
      @editable << form
      @tabs.append("Settings", form, margined: true)
      @tabs.append("JSON (all settings)", @editor, margined: true)
      @tabs.append("Log (last 64 KiB)", @log_view, margined: true)
      @tabs
    end

    private def run_options
      box = UIng::Box.new(:vertical, padded: true)
      if replay = @replay
        row = UIng::Box.new(:horizontal, padded: true)
        row.append(UIng::Label.new("Sequence replay JSONL"))
        replay.text = "examples/replay.jsonl"
        row.append(replay, stretchy: true)
        @editable << replay
        button("Browse…", row) do
          if path = @window.open_file
            replay.text = path
          end
        end
        box.append(row)
      end
      row = UIng::Box.new(:horizontal, padded: true)
      row.append(@mode, stretchy: true)
      @editable << @mode
      box.append(row)
      box
    end

    private def fill_fields
      Profile.fields.each do |field|
        value = @document.get(field.key)
        if field.kind == :bool
          @checks[field.key].checked = value.as_bool
        else
          @entries[field.key].text = case field.kind
                                     when :list then value.as_a.map(&.as_s).join(", ")
                                     else            value.raw.nil? ? "" : value.as_s? || value.to_s
                                     end
          @original_text[field.key] = @entries[field.key].text || ""
        end
      end
    end

    private def synchronize_document
      candidate = if @last_tab == 1
                    Profile.parse(@editor.text || "")
                  else
                    copy = Document.new(@document.text)
                    Profile.fields.each do |field|
                      if field.kind == :bool
                        copy.set(field.key, JSON::Any.new(@checks[field.key].checked?))
                      else
                        text = @entries[field.key].text || ""
                        copy.set_text(field, text) unless text == @original_text[field.key]
                      end
                    end
                    Profile.parse(copy.text)
                  end
      @document = candidate
      fill_fields
    end

    def select_tab(index : Int32)
      return unless switch_tab(index)
      @tabs.selected = index
    end

    private def switch_tab(index : Int32) : Bool
      return true if @switching
      @switching = true
      begin
        synchronize_document unless @runner.busy?
        @editor.text = @document.text if index == 1
        @last_tab = index
        true
      rescue error
        @tabs.selected = @last_tab
        @window.msg_box_error("Invalid configuration", error.message || error.to_s)
        false
      ensure
        @switching = false
      end
    end

    private def set_busy(busy : Bool)
      @editable.each { |control| busy ? control.disable : control.enable }
      @editor.read_only = busy
      @actions.each do |action, item|
        next if action == :settings
        enabled = action == :stop ? busy : !busy
        enabled ? item.enable : item.disable
      end
    end
  end
end
