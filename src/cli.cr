require "option_parser"
require "./adaptive"
require "./adaptive/diagnostic"

module Adaptive
  def self.cli(policy_factory : Config -> Policy = ->(config : Config) { BuiltinPolicy.new(config).as(Policy) }) : Nil
    config_path = "examples/live.json"
    replay_path = nil
    validate = false
    check_backend = false
    signal_path = nil
    metadata_path = nil
    OptionParser.parse do |parser|
      parser.banner = "adaptive #{VERSION}: programmable Read Until"
      parser.on("-c FILE", "--config=FILE", "JSON configuration") { |value| config_path = value }
      parser.on("--replay=FILE", "Offline policy replay from sequence JSONL") { |value| replay_path = value }
      parser.on("--validate", "Validate config and reference index") { validate = true }
      parser.on("--check-backend", "Verify basecaller connection without MinKNOW") { check_backend = true }
      parser.on("--check-signal=FILE", "Basecall a real little-endian int16 ADC file without MinKNOW") { |value| signal_path = value }
      parser.on("--signal-metadata=FILE", "Calibration JSON for --check-signal") { |value| metadata_path = value }
      parser.on("--version", "Show version") { puts VERSION; exit }
      parser.on("-h", "--help", "Show help") { puts parser; exit }
    end
    raise "select only one of --validate, --replay, --check-backend, --check-signal" if [validate, !replay_path.nil?, check_backend, !signal_path.nil?].count(true) > 1
    raise "--check-signal and --signal-metadata must be used together" unless signal_path.nil? == metadata_path.nil?
    config = Config.from_json(File.read(config_path))
    config.validate!
    policy = policy_factory.call(config)
    if validate
      index = Minimap2::Aligner.new(config.reference, preset: "map-ont").validate_targets!(config)
      puts "OK: #{index.n_seq} references, #{config.workers} workers"
    elsif check_backend || signal_path
      check_backend(config, signal_path, metadata_path)
    elsif path = replay_path
      replay(config, policy, path)
    else
      Live.new(config, policy).run
    end
  rescue ex
    STDERR.puts "adaptive: #{ex.message}"
    exit 1
  end
end
