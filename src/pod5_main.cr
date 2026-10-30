require "option_parser"
require "./adaptive/pod5_export"

begin
  samples = 20000
  read_id = nil.as(String?)
  OptionParser.parse do |parser|
    parser.banner = "adaptive-pod5 INPUT.pod5 NEW_DIRECTORY [--samples=N] [--read-id=UUID]"
    parser.on("--samples=N", "Prefix samples (100..250000; default 20000)") { |value| samples = value.to_i }
    parser.on("--read-id=UUID", "Select read (default: first with at least 100 samples)") { |value| read_id = value }
    parser.on("-h", "--help", "Show help") { puts parser; exit }
  end
  raise "expected INPUT.pod5 and NEW_DIRECTORY; see --help" unless ARGV.size == 2
  Adaptive::Pod5Export.export(ARGV[0], ARGV[1], samples, read_id)
rescue ex
  STDERR.puts "adaptive-pod5: #{ex.message}"
  exit 1
end
