require "spec"
require "../src/adaptive/bridge"
require "../src/adaptive/sequence"

describe Adaptive::Bridge do
  it "accepts an explicitly bounded full read and preserves the original molecule id" do
    config = Adaptive::Config.from_json({reference: "examples/reference.fa", targets: ["virus"],
                                         fixture_sequence: "ACGT", allow_test_bridge: true, bridge_max_signal_bytes: 600000,
                                         bridge_max_response_bytes: 4194304}.to_json)
    config.validate!
    bridge = Adaptive::Bridge.new(config)
    begin
      bridge.info["max_response_bytes"].as_i.should eq(4194304)
      job = Adaptive::Job.new(1, "original-read", 0_u64, Bytes.new(500002), 0.0, 0.25, 5000.0, 0_u64)
      result = bridge.basecall(job)
      result.read_id.should eq("original-read")
      result.sequences.should eq(["ACGT"])
      result.segments.first.quality.should be_nil
      expect_raises(ArgumentError, /signal/) do
        bridge.basecall(Adaptive::Job.new(1, "oversized", 0_u64, Bytes.new(600002), 0.0, 0.25, 5000.0, 0_u64))
      end
      bridge.call(job).should eq(["ACGT"])
    ensure
      bridge.close
    end
    [199, 500001, 67108866].each do |limit|
      config.bridge_max_signal_bytes = limit
      expect_raises(Exception, /bridge signal limit/) { config.validate! }
    end
    config.bridge_max_signal_bytes = 500000
    [1023, 67108865].each do |limit|
      config.bridge_max_response_bytes = limit
      expect_raises(Exception, /bridge response limit/) { config.validate! }
    end
  end
end

describe Adaptive::BasecallResult do
  it "keeps separate segments, qualities, strand and CIGAR through mapping and JSON" do
    config = Adaptive::Config.from_json({reference: "examples/reference.fa", targets: ["virus"], min_bases: 1}.to_json)
    sequence = JSON.parse(File.read("examples/replay.jsonl").lines[1])["sequences"][0].as_s
    reverse = sequence.reverse.tr("ACGT", "TGCA")
    calls = Adaptive::BasecallResult.new("split", [
      Adaptive::BasecallSegment.new(sequence, "I" * sequence.size, "child-one"),
      Adaptive::BasecallSegment.new(reverse, "J" * reverse.size, "child-two"),
    ])
    mapper = Adaptive::SequenceMapper.new(config)
    evidence = mapper.map(calls.sequences, channel: 2, read_id: "split", basecalls: calls,
      source: Adaptive::EvidenceSource::Basecall)
    restored = Adaptive::Evidence.from_json(evidence.to_json)
    restored.basecalls.should eq(calls)
    restored.hits.should eq(evidence.hits)
    restored.hits.map(&.segment).uniq!.sort!.should eq([0, 1])
    restored.hits.any?(&.mapping.strand.reverse?).should be_true
    restored.hits.all? { |hit| !hit.mapping.cigar.empty? }.should be_true
    expect_raises(ArgumentError, /match evidence/) do
      mapper.map([sequence], channel: 2, read_id: "different", basecalls: calls)
    end
    expect_raises(ArgumentError, /quality/) { Adaptive::BasecallSegment.new("ACGT", "III").validate! }
    expect_raises(ArgumentError, /quality/) { Adaptive::BasecallSegment.new("ACGT", "III\n").validate! }
  end
end
