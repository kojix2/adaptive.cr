require "option_parser"
require "./window"

module NanoporeGUI
  def self.run
    executable = File.join(File.dirname(Process.executable_path || PROGRAM_NAME), Profile.command)
    directory = Dir.current
    config : String? = nil
    information_only = false
    parser = OptionParser.new do |options|
      options.banner = "Usage: #{Profile.command}-gui [options]"
      options.on("-c PATH", "--config=PATH", "Open a JSON configuration") { |value| config = File.expand_path(value) }
      options.on("--workdir=PATH", "Working directory for relative config paths") { |value| directory = File.expand_path(value) }
      options.on("--cli=PATH", "CLI executable (default: sibling binary)") { |value| executable = File.expand_path(value) }
      options.on("--version", "Show version") { puts "#{Profile.command}-gui #{Profile.version}"; information_only = true }
      options.on("-h", "--help", "Show help") { puts options; information_only = true }
    end
    parser.parse
    return if information_only
    raise "Unexpected arguments: #{ARGV.join(" ")}" unless ARGV.empty?
    UIng.init do
      app = Window.new(executable, directory)
      UIng.main_steps
      begin
        if path = config
          app.load_config(path)
        end
        app.show
        run_loop(app)
      ensure
        app.request_close
        run_loop(app)
      end
    end
  rescue error
    STDERR.puts "#{Profile.command}-gui: #{error.message}"
    exit 1
  end

  private def self.run_loop(app : Window)
    until app.closed?
      UIng.main_step(false)
      app.pump
      sleep 10.milliseconds
    end
  end
end
