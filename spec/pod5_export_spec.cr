require "spec"
require "../src/adaptive/pod5_export"
require "../src/adaptive/diagnostic"

private def with_pod5_export(&)
  directory = File.join(Dir.tempdir, "adaptive-pod5-#{UUID.random}")
  Dir.mkdir(directory)
  begin
    yield directory
  ensure
    FileUtils.rm_rf(directory)
  end
end

private def export_fixture(directory)
  path = File.join(directory, "source.pod5")
  run = Pod5::RunInfo.new(acquisition_id: "export", sample_rate: 5000_u16)
  metadata = Pod5::Metadata.new(run_info: run, channel: 42_u32,
    calibration_offset: -12.5_f32, calibration_scale: 0.25_f32, start_sample: 12345_u64)
  signal = Slice(Int16).new(32769) { |i| (i % 1000 - 500).to_i16 }
  Pod5::Writer.open(path) do |writer|
    writer.add(Pod5::Metadata.new(run_info: run, channel: 1_u32), Slice[0_i16])
    writer.add(metadata, signal)
  end
  {path, metadata, signal}
end

describe Adaptive::Pod5Export do
  it "exports unchanged ADC across the 64 KiB boundary with original calibration" do
    with_pod5_export do |directory|
      source, metadata, signal = export_fixture(directory)
      output = File.join(directory, "prefix")
      Adaptive::Pod5Export.export(source, output, 40000)
      File.open(File.join(output, "prefix.i16")) do |file|
        signal.each { |adc| file.read_bytes(Int16, IO::ByteFormat::LittleEndian).should eq(adc) }
        file.read_byte.should be_nil
      end
      calibration = Adaptive::SignalMetadata.from_json(File.read(File.join(output, "prefix.json")))
      calibration.validate!
      calibration.offset.should eq(-12.5)
      calibration.scale.should eq(0.25)
      calibration.sample_rate.should eq(5000)
      calibration.start_sample.should eq(metadata.start_sample)
      JSON.parse(File.read(File.join(output, "read.json")))["read_id"].as_s.should eq(metadata.read_id.to_s)
    end
  end

  it "selects a UUID, truncates the prefix and refuses an existing destination" do
    with_pod5_export do |directory|
      source, metadata, _ = export_fixture(directory)
      output = File.join(directory, "prefix")
      Adaptive::Pod5Export.export(source, output, 100, metadata.read_id.to_s)
      File.size(File.join(output, "prefix.i16")).should eq(200)
      expect_raises(File::AlreadyExistsError) { Adaptive::Pod5Export.export(source, output) }
      File.size(File.join(output, "prefix.i16")).should eq(200)
    end
  end

  it "removes incomplete output on a missing UUID" do
    with_pod5_export do |directory|
      source, _, _ = export_fixture(directory)
      output = File.join(directory, "missing")
      expect_raises(KeyError) { Adaptive::Pod5Export.export(source, output, 100, UUID.random.to_s) }
      Dir.exists?(output).should be_false
      expect_raises(ArgumentError) { Adaptive::Pod5Export.export(source, output, 99) }
      Dir.exists?(output).should be_false
    end
  end
end
