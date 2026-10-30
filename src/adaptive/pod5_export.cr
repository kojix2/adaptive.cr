require "pod5"
require "json"
require "file_utils"

module Adaptive
  # Preserve raw ADC and calibration for the existing Dorado diagnostic.
  module Pod5Export
    MAX_READ_SAMPLES = 10_000_000_u64

    def self.export(source : String, destination : String, samples : Int32 = 20000, read_id : String? = nil) : Nil
      raise ArgumentError.new("samples must be 100..250000") unless (100..250000).includes?(samples)
      selected_id = read_id.try { |id| UUID.new(id) }
      Dir.mkdir(destination)
      begin
        Pod5::Reader.open(source) do |reader|
          if id = selected_id
            write(reader[id], destination, samples)
          else
            found = false
            reader.each do |record|
              next if record.sample_count < 100
              write(record, destination, samples)
              found = true
              break
            end
            raise "no read with at least 100 samples" unless found
          end
        end
      rescue ex
        FileUtils.rm_rf(destination)
        raise ex
      end
    end

    private def self.write(record : Pod5::Record, destination : String, samples : Int32) : Nil
      raise "read must contain 100..#{MAX_READ_SAMPLES} samples" unless (100_u64..MAX_READ_SAMPLES).includes?(record.sample_count)
      offset = record.calibration_offset.to_f64
      scale = record.calibration_scale.to_f64
      rate = record.run_info.sample_rate.to_f64
      raise "invalid signal calibration" unless offset.finite? && scale.finite? && scale > 0 && rate > 0
      # pod5.cr currently decodes a full read; bound that allocation explicitly.
      signal = record.signal
      count = Math.min(samples, signal.size)
      File.open(File.join(destination, "prefix.i16"), "w") do |file|
        if IO::ByteFormat::SystemEndian == IO::ByteFormat::LittleEndian
          file.write(signal.to_unsafe.as(UInt8*).to_slice(count * 2))
        else
          count.times { |i| file.write_bytes(signal[i], IO::ByteFormat::LittleEndian) }
        end
      end
      File.write(File.join(destination, "prefix.json"), {
        offset: offset, scale: scale, sample_rate: rate, start_sample: record.start_sample,
      }.to_pretty_json + "\n")
      File.write(File.join(destination, "read.json"), {
        read_id: record.read_id.to_s, channel: record.channel,
        original_samples: record.sample_count, exported_samples: count,
      }.to_pretty_json + "\n")
    end
  end
end
