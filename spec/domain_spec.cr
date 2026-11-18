require "spec"
require "../src/adaptive/live"

private def domain_native_mapping(primary : Bool, secondary : Bool)
  Minimap2::Mapping.new(0, 10, Minimap2::Strand::Reverse, "target", 20, 5, 15, 10, 10,
    40_u32, primary, [{10_u32, 0_u8}], "10M", 0, nil, nil, nil, secondary, true)
end

describe "ADC signal interpretation" do
  it "accepts only a declared signed little-endian int16 stream" do
    response = MinknowApi::Data::GetDataTypesResponse.new
    expect_raises(ArgumentError, /missing ADC/) { Adaptive::Live.validate_signal_format(response) }
    description = MinknowApi::Data::GetDataTypesResponse::DataType.new
    description.size = 2_u32
    response.uncalibrated_signal = description
    decoded = MinknowApi::Data::GetDataTypesResponse.decode(response.encode)
    Adaptive::Live.validate_signal_format(decoded).should eq(Adaptive::SignalFormat::AdcInt16LE)
    description.big_endian = true
    expect_raises(ArgumentError, /unsupported signal format/) { Adaptive::Live.validate_signal_format(response) }
    description.big_endian = false
    description.size = 4_u32
    expect_raises(ArgumentError, /unsupported signal format/) { Adaptive::Live.validate_signal_format(response) }
    description.size = 2_u32
    [1, 2, 99].each do |kind|
      description.type_ = Proto::OpenEnum(MinknowApi::Data::GetDataTypesResponse::DataType::Type).new(kind)
      expect_raises(ArgumentError, /unsupported signal format/) { Adaptive::Live.validate_signal_format(response) }
    end
  end

  it "preserves signed ADC values, sample counts and the acquisition context" do
    values = [-32768_i16, -3_i16, 0_i16, 1_i16, 32767_i16]
    raw = IO::Memory.new
    values.each { |value| raw.write_bytes(value, IO::ByteFormat::LittleEndian) }
    prefix = Adaptive::SignalPrefix.new.append(raw.to_slice[0, 4]).append(raw.to_slice[4..])
    prefix.samples.should eq(values.size)
    expect_raises(ArgumentError, /whole int16/) { prefix.append(Bytes[1]) }
    context = Adaptive::SignalContext.new(-12.5, 0.14, 5000.0, 1234_u64)
    job = Adaptive::Job.new(1, "parent", 1_u64, prefix, context)
    job.samples.should eq(5)
    job.start_sample.should eq(1234)
    job.scale.should eq(0.14)
    io = IO::Memory.new
    job.write_signal(io)
    io.rewind
    Array.new(values.size) { io.read_bytes(Int16, IO::ByteFormat::LittleEndian) }.should eq(values)
    expect_raises(ArgumentError, /whole int16/) { job.copy_with(signal: Bytes[1]) }
    expect_raises(ArgumentError, /calibration/) { job.copy_with(context: context.copy_with(scale: 0.0)) }
    expect_raises(ArgumentError, /sample rate/) { job.copy_with(context: context.copy_with(sample_rate: Float64::NAN)) }
    Adaptive::SignalContext.from_json(context.to_json).should eq(context)
  end
end

describe "Alignment classification" do
  it "preserves native primary, secondary, supplementary and inversion facts through JSON" do
    cases = [{true, false, Adaptive::AlignmentClass::Primary},
             {false, true, Adaptive::AlignmentClass::Secondary},
             {false, false, Adaptive::AlignmentClass::Supplementary}]
    cases.each do |primary, secondary, expected|
      mapping = Adaptive::Mapping.from_minimap2(domain_native_mapping(primary, secondary))
      restored = Adaptive::Mapping.from_json(mapping.to_json)
      restored.classification.should eq(expected)
      restored.inversion.should be_true
      restored.strand.should eq(Adaptive::Strand::Reverse)
      restored.secondary?.should eq(expected.secondary?)
      restored.supplementary?.should eq(expected.supplementary?)
    end
  end

  it "keeps legacy non-primary classification unknown and rejects contradictory flags" do
    legacy = Adaptive::Mapping.from_json(%({"target_name":"target","is_primary":false}))
    legacy.classification.should eq(Adaptive::AlignmentClass::Unknown)
    legacy.secondary.should be_nil
    expect_raises(ArgumentError, /cannot be secondary/) do
      Adaptive::Mapping.from_json(%({"target_name":"target","is_primary":true,"secondary":true}))
    end
  end
end

describe "Basecall provenance and canonical sequences" do
  it "keeps an explicit parent-relative interval distinct from native timing and acquisition position" do
    response = Adaptive::BasecallResponse.from_json(%({"id":"request","segments":[{"sequence":"ACGT","read_id":"child","signal_span":{"start_sample":20,"end_sample":80},"native_timing":{"start_time":1000,"duration":100,"trimmed_samples":20,"trimmed_duration":60}}]}))
    context = Adaptive::SignalContext.new(-12.5, 0.14, 5000.0, 1000_u64)
    calls = Adaptive::BasecallResult.from_bridge_response(response, "parent", "request",
      input_samples: 100, signal_context: context)
    restored = Adaptive::BasecallResult.from_json(calls.to_json)
    restored.should eq(calls)
    restored.read_id.should eq("parent")
    restored.segments.first.read_id.should eq("child")
    span = restored.segments.first.signal_span.should_not be_nil
    span.start_sample.should eq(20)
    span.end_sample.should eq(80)
    restored.signal_context.should eq(context)
    restored.input_samples.should eq(100)
    timing = restored.segments.first.native_timing.should_not be_nil
    timing.start_time.should eq(1000)
    timing.trimmed_duration.should eq(60)
  end

  it "does not invent an interval from length, child order or native timing" do
    response = Adaptive::BasecallResponse.from_json(%({"id":"request","segments":[{"sequence":"ACGT","native_timing":{"start_time":1000,"duration":100}},{"sequence":""}]}))
    calls = Adaptive::BasecallResult.from_bridge_response(response, "parent", "request", input_samples: 100)
    calls.segments.each(&.signal_span.should(be_nil))
    calls.segments.last.native_timing.should be_nil
    expect_raises(ArgumentError, /reversed signal interval/) { Adaptive::SampleInterval.new(80_u64, 20_u64) }
    segment = calls.segments.first.copy_with(signal_span: Adaptive::SampleInterval.new(0_u64, 101_u64))
    expect_raises(ArgumentError, /exceeds input/) { Adaptive::BasecallResult.new("parent", [segment], 100) }
    empty_span = calls.segments.first.copy_with(signal_span: Adaptive::SampleInterval.new(0_u64, 0_u64))
    expect_raises(ArgumentError, /nonempty signal interval/) { Adaptive::BasecallResult.new("parent", [empty_span], 100) }
    expect_raises(ArgumentError, /reversed signal interval/) do
      Adaptive::BasecallResult.from_json(%({"read_id":"parent","segments":[{"sequence":"ACGT","signal_span":{"start_sample":80,"end_sample":20}}]}))
    end
  end

  it "isolates canonical segments from caller mutation and derives compatibility sequence arrays" do
    segments = [Adaptive::BasecallSegment.new("ACGT", "IIII", "child")]
    calls = Adaptive::BasecallResult.new("parent", segments, 100)
    sequences = calls.sequences
    evidence = Adaptive::Evidence.new(1, "parent", 100, sequences, [] of Adaptive::Hit,
      source: Adaptive::EvidenceSource::Basecall, basecalls: calls)
    segments.clear
    sequences.clear
    calls.sequences.clear
    evidence.sequences.clear
    evidence.sequences.should eq(["ACGT"])
    calls.segments.size.should eq(1)
    calls.segments.read_only?.should be_true
    evidence.base_count.should eq(4)
    json = JSON.parse(evidence.to_json)
    json["sequences"][0].as_s.should eq(json["basecalls"]["segments"][0]["sequence"].as_s)
    Adaptive::Evidence.from_json(evidence.to_json).sequences.should eq(["ACGT"])
    evidence.basecalls.should eq(calls)
    expect_raises(ArgumentError, /match evidence/) do
      Adaptive::Evidence.new(1, "parent", 101, ["ACGT"], [] of Adaptive::Hit, basecalls: calls)
    end
  end

  it "accepts consistent legacy JSON and rejects mismatched duplicated sequence information" do
    calls = Adaptive::BasecallResult.new("parent", [Adaptive::BasecallSegment.new("ACGT")])
    legacy = {channel: 1, read_id: "parent", samples: 100, sequences: ["ACGT"], hits: [] of Adaptive::Hit, basecalls: calls}
    Adaptive::Evidence.from_json(legacy.to_json).sequences.should eq(["ACGT"])
    expect_raises(ArgumentError, /match evidence/) do
      Adaptive::Evidence.from_json(legacy.merge({sequences: ["TTTT"]}).to_json)
    end
    plain = Adaptive::Evidence.new(1, "plain", 0, ["ACGT"], [] of Adaptive::Hit)
    plain.sequences.clear
    Adaptive::Evidence.from_json(plain.to_json).sequences.should eq(["ACGT"])
  end

  it "checks segment indices and query bounds against the canonical sequences" do
    hit = Adaptive::Hit.new(1, Adaptive::Mapping.new("target"))
    expect_raises(ArgumentError, /segment index/) { Adaptive::Evidence.new(1, "read", 0, ["ACGT"], [hit]) }
    hit = Adaptive::Hit.new(0, Adaptive::Mapping.new("target", query_end: 5))
    expect_raises(ArgumentError, /exceeds query/) { Adaptive::Evidence.new(1, "read", 0, ["ACGT"], [hit]) }
  end

  it "preserves segment association and CIGAR spans for reverse strands and indels" do
    config = Adaptive::Config.from_json(%({"reference":"examples/reference.fa","targets":["virus"],"min_bases":1}))
    mapper = Adaptive::SequenceMapper.new(config)
    original = JSON.parse(File.read("examples/replay.jsonl").lines[1])["sequences"][0].as_s
    sequences = [original, Minimap2.revcomp(original),
                 original[0, 200] + "AAAAAAA" + original[200..], original[0, 200] + original[207..]]
    calls = Adaptive::BasecallResult.new("parent", sequences.map { |sequence| Adaptive::BasecallSegment.new(sequence) }, 5000)
    evidence = mapper.map(calls, channel: 1)
    evidence.samples.should eq(5000)
    evidence.basecalls.should eq(calls)
    evidence.hits.map(&.segment).uniq!.sort!.should eq([0, 1, 2, 3])
    evidence.hits.any?(&.mapping.strand.reverse?).should be_true
    evidence.hits.each do |hit|
      mapping = hit.mapping
      query_consumed = mapping.cigar.sum { |len, op| {0_u8, 1_u8, 7_u8, 8_u8}.includes?(op) ? len.to_i : 0 }
      target_consumed = mapping.cigar.sum { |len, op| {0_u8, 2_u8, 3_u8, 7_u8, 8_u8}.includes?(op) ? len.to_i : 0 }
      query_consumed.should eq(mapping.query_end - mapping.query_start)
      target_consumed.should eq(mapping.target_end - mapping.target_start)
      mapping.query_end.should be <= calls.segments[hit.segment].sequence.bytesize
    end
  end
end
