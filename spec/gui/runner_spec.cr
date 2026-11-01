require "spec"
require "../../src/gui/runner"

private def wait_for_gui_runner(runner : NanoporeGUI::Runner)
  deadline = Time.instant + 5.seconds
  while runner.busy? && Time.instant < deadline
    sleep 5.milliseconds
  end
  runner.busy?.should be_false
end

private def with_gui_cli(script : String, &)
  file = File.tempfile("gui cli with spaces-", ".sh")
  begin
    file << "#!/bin/sh\n" << script
    file.close
    File.chmod(file.path, 0o700)
    yield file.path
  ensure
    file.close
    File.delete?(file.path)
  end
end

module NanoporeGUI
  describe LogBuffer do
    it "bounds noisy output and keeps the latest text" do
      log = LogBuffer.new
      log << "x" * (LogBuffer::LIMIT * 3) << "last line\n"
      log.text.bytesize.should eq(LogBuffer::LIMIT)
      log.text.should end_with("last line\n")
    end

    it "accepts malformed byte sequences without breaking the UI" do
      log = LogBuffer.new
      log.write(Bytes[0xff, 0xfe, 10])
      log.text.valid_encoding?.should be_true
    end
  end

  describe Runner do
    it "passes a private config snapshot and literal arguments, drains both pipes and can restart" do
      runner = Runner.new
      script = "test -r \"$2\" || exit 9; cat \"$2\"; printf '%s' \"$3\"; printf stderr >&2; exit 7"
      with_gui_cli(script) do |executable|
        2.times do
          runner.start(executable, ["literal $(echo unsafe) ; space"], "{\"channels\":2}", Dir.current)
          snapshot = (runner.snapshot_path || raise "Missing run snapshot")
          wait_for_gui_runner(runner)
          runner.exit_code.should eq(7)
          runner.log.text.should contain("literal $(echo unsafe) ; space")
          runner.log.text.should contain("stderr")
          runner.log.text.should contain("{\"channels\":2}")
          File.exists?(snapshot).should be_false
          runner.snapshot_path.should be_nil
        end
      end
    end

    it "cleans up and permits retry after an executable fails to start" do
      runner = Runner.new
      expect_raises(IO::Error) { runner.start("/missing/nanopore-gui-cli", [] of String, "{}", Dir.current) }
      runner.busy?.should be_false
      runner.snapshot_path.should be_nil
    end

    it "rejects overlapping runs and reaps a stopped process" do
      runner = Runner.new
      with_gui_cli("trap 'exit 0' TERM; while :; do :; done") do |executable|
        runner.start(executable, [] of String, "{}", Dir.current)
        snapshot = (runner.snapshot_path || raise "Missing run snapshot")
        sleep 50.milliseconds
        expect_raises(Exception, /already running/) do
          runner.start("/bin/sh", [] of String, "exit 0", Dir.current)
        end
        runner.stop
        wait_for_gui_runner(runner)
        File.exists?(snapshot).should be_false
      end
    end
  end
end
