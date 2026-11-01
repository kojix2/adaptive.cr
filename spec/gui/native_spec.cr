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
