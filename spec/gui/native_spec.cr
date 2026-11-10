# Native display tests are enabled by scripts/test-gui.sh.
{% if env("NANOPORE_GUI_TESTS") == "1" %}
  require "spec"
  require "../../src/gui/window"

  private def pump_until(app : NanoporeGUI::Window, &condition : -> Bool)
    deadline = Time.instant + 30.seconds
    until condition.call
      raise "GUI smoke test timed out" if Time.instant > deadline
      UIng.main_step(false)
      app.pump
      sleep 10.milliseconds
    end
  end

  NanoporeGUI::Translations.setup("en")

  describe "Native GUI" do
    it "edits configuration, runs the CLI and releases the toolbar and child process" do
      UIng.init do
        root = File.expand_path("../..", __DIR__)
        executable = File.join(root, "bin", NanoporeGUI::Profile.command)
        app = NanoporeGUI::Window.new(executable, root)
        UIng.main_steps
        app.show
        begin
          raise "Native toolbar was not attached" unless app.toolbar.attached?
          raise "Settings icon action is missing" unless app.actions[:settings].text == "Settings"
          raise "Stop must start disabled" if app.actions[:stop].enabled?
          config = NanoporeGUI::Profile.initial
          raise "Observe must default to true" unless config.get("observe").as_bool
          file = File.tempfile("gui-smoke-", ".json")
          begin
            file << config.text
            file.close
            app.load_config(file.path)
            app.select_tab(1)
            config.set("seed", JSON::Any.new(987654_i64))
            app.editor.text = config.text
            app.select_tab(0)
            app.save_config(file.path)
            raise "Saving changed configuration" unless JSON.parse(File.read(file.path)) == config.value
            app.launch(:validate)
            raise "Start must be disabled while running" if app.actions[:start].enabled?
            raise "Save must be disabled while running" if app.actions[:save].enabled?
            raise "Stop must be enabled while running" unless app.actions[:stop].enabled?
            pump_until(app) { !app.runner.busy? }
            app.pump
            raise "Start was not re-enabled" unless app.actions[:start].enabled?
            raise "Stop was not disabled after completion" if app.actions[:stop].enabled?
            raise "GUI validation failed: #{app.runner.log.text}" unless app.runner.exit_code == 0
            app.mode.selected = 1
            app.replay.try(&.text=("examples/replay.jsonl"))
            app.launch
            pump_until(app) { !app.runner.busy? }
            raise "GUI offline run failed: #{app.runner.log.text}" unless app.runner.exit_code == 0
            raise "Missing replay decisions" unless app.runner.log.text.includes?("Reject")
          ensure
            file.close
            File.delete?(file.path)
          end
        ensure
          app.request_close
          pump_until(app) { app.closed? }
          raise "Child still running after close" if app.runner.busy?
        end
        raise "Native toolbar was not freed on close" unless app.toolbar.released?
      end
    end
  end
{% end %}

{% if env("NANOPORE_GUI_TESTS") == "1" %}
  describe "Translated native GUI" do
    NanoporeGUI::Translations::SUPPORTED_LOCALES.each do |locale|
      it "opens and preserves configuration in #{locale}" do
        NanoporeGUI::Translations.setup(locale)
        UIng.init do
          app = NanoporeGUI::Window.new("/bin/true", Dir.current)
          UIng.main_steps
          file = File.tempfile("localized-gui-", ".json")
          file.close
          begin
            app.show
            UIng.main_step(false)
            app.pump
            app.actions[:start].text.should eq(NanoporeGUI.t("Start"))
            app.actions[:settings].text.should eq(NanoporeGUI.t("Settings"))
            app.mode.num_items.should eq(2)
            before = app.document.value
            app.select_tab(1)
            app.select_tab(0)
            app.save_config(file.path)
            JSON.parse(File.read(file.path)).should eq(before)
            app.actions[:stop].enabled?.should be_false
          ensure
            file.close
            File.delete?(file.path)
            app.request_close
            pump_until(app) { app.closed? }
          end
          app.toolbar.released?.should be_true
        end
      ensure
        NanoporeGUI::Translations.setup("en")
      end
    end
  end
{% end %}

{% if env("NANOPORE_GUI_TESTS") == "1" %}
  describe "Native GUI thread affinity" do
    it "stays on the main thread when a child process fails during startup" do
      main_thread = Thread.current
      file = File.tempfile("failing-gui-cli-", ".sh")
      begin
        file << "#!/bin/sh\nprintf '%s\\n' 'startup failed' >&2\nexit 7\n"
        file.close
        File.chmod(file.path, 0o700)
        UIng.init do
          app = NanoporeGUI::Window.new(file.path, Dir.current)
          UIng.main_steps
          begin
            app.show
            app.launch
            deadline = Time.instant + 10.seconds
            until !app.runner.busy? && app.actions[:start].enabled?
              raise "Failed process did not stop" if Time.instant > deadline
              Thread.current.should be(main_thread)
              UIng.main_step(false)
              app.pump
              sleep 10.milliseconds
            end
            Thread.current.should be(main_thread)
            app.runner.exit_code.should eq(7)
            app.runner.log.text.should contain("startup failed")
            app.actions[:stop].enabled?.should be_false
            # Verify that process I/O did not leave UI updates or teardown on
            # another OS thread, and that the runner can be used again.
            app.launch
            pump_until(app) do
              Thread.current.should be(main_thread)
              !app.runner.busy? && app.actions[:start].enabled?
            end
            app.runner.exit_code.should eq(7)
          ensure
            Thread.current.should be(main_thread)
            app.request_close
            pump_until(app) do
              Thread.current.should be(main_thread)
              app.closed?
            end
          end
          Thread.current.should be(main_thread)
          app.toolbar.released?.should be_true
        end
      ensure
        file.close
        File.delete?(file.path)
      end
    end
  end
{% end %}
