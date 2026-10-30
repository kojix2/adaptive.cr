require "./bridge"

module Adaptive
  class SignalMetadata
    include JSON::Serializable
    include JSON::Serializable::Strict
    getter offset : Float64
    getter scale : Float64
    getter sample_rate : Float64
    getter start_sample : UInt64

    def validate! : Nil
      raise "invalid signal calibration" unless offset.finite? && scale.finite? && scale > 0 && sample_rate.finite? && sample_rate > 0
    end
  end

  # Checks the real adapter path without opening a MinKNOW stream. Input must
  # be actual little-endian int16 ADC data with its own calibration metadata.
  def self.check_backend(config : Config, signal_path : String?, metadata_path : String?) : Nil
    job = nil
    if signal_path && metadata_path
      size = File.size(signal_path)
      raise "signal must contain 100..250000 int16 samples" unless (200..500000).includes?(size) && size.even?
      metadata = SignalMetadata.from_json(File.read(metadata_path))
      metadata.validate!
      job = Job.new(1, UUID.random.to_s, 0_u64, File.read(signal_path).to_slice,
        metadata.offset, metadata.scale, metadata.sample_rate, metadata.start_sample)
    end
    bridge = Bridge.new(config)
    if job
      sequences = bridge.call(job)
      raise "basecaller returned no bases for diagnostic signal" if sequences.all?(&.empty?)
      puts({status: "ok", check: "basecall", backend: bridge.info,
            samples: job.signal.size // 2, sequences: sequences}.to_json)
    else
      puts({status: "ok", check: "connection", backend: bridge.info}.to_json)
    end
  ensure
    bridge.try &.close
  end
end
