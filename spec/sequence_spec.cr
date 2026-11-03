require "spec"
require "../src/adaptive/sequence"
require "../src/adaptive/replay"

private def sequence_config
  Adaptive::Config.from_json(%({"reference":"examples/reference.fa","targets":["virus"],"min_bases":1}))
end

private def replay_sequences
  File.read("examples/replay.jsonl").lines.first(2).map { |line| JSON.parse(line)["sequences"].as_a.map(&.as_s) }
end

class SequenceMemoryPolicy < Adaptive::Policy
  getter counts = [] of Int32

  def decide(read : Adaptive::Evidence, experiment : Adaptive::Experiment, memory : Hash(String, String)) : Adaptive::Decision
    count = (memory["count"]? || "0").to_i + 1
    memory["count"] = count.to_s
    @counts << count
    Adaptive::Decision.new(count < 2 ? Adaptive::Choice::Continue : Adaptive::Choice::Accept, "memory")
  end
end

describe Adaptive::SequenceMapper do
  it "maps separate segments with metadata, neutral coordinates and source intact" do
    mapper = Adaptive::SequenceMapper.new(sequence_config)
    host, virus = replay_sequences
    sequences = [host.first, "", virus.first]
    evidence = mapper.map(sequences, channel: 7, read_id: "split", samples: 1234)
    evidence.channel.should eq(7)
    evidence.read_id.should eq("split")
    evidence.samples.should eq(1234)
    evidence.sequences.should eq(sequences)
    evidence.source.should eq(Adaptive::EvidenceSource::Sequence)
    evidence.hits.map(&.segment).uniq!.sort!.should eq([0, 2])
    hit = evidence.hits.find! { |item| item.segment == 2 }
    mapping = hit.mapping
    mapping.should be_a(Adaptive::Mapping)
    mapping.target_name.should eq("virus")
    mapping.mapq.should eq(60)
    mapping.target_end.should be > mapping.target_start
    mapping.target_len.should be >= mapping.target_end
    mapping.query_end.should be <= virus.first.size
    mapping.block_len.should be > 0
    mapping.cigar.should_not be_empty
    sequences.clear
    evidence.sequences.size.should eq(3)
    mapper.map(virus, channel: 1, read_id: "called", source: Adaptive::EvidenceSource::Basecall)
      .source.should eq(Adaptive::EvidenceSource::Basecall)
  end

  it "validates sequence settings without Python, bridge or connection settings" do
    config = sequence_config
    config.python = "/does/not/exist"
    config.bridge_script = "/does/not/exist.py"
    config.host = ""
    config.port = 0
    mapper = Adaptive::SequenceMapper.new(config)
    evaluation = mapper.evaluate(replay_sequences.last, Adaptive::BuiltinPolicy.new(config), Adaptive::Experiment.new,
      {} of String => String, channel: 1, read_id: "offline")
    evaluation.decision.choice.should eq(Adaptive::Choice::Accept)
    expect_raises(Exception, /port/) { config.validate! }
    config.mapq = 61_u32
    expect_raises(Exception, /MAPQ/) { mapper.validate!(config) }
    config.mapq = 20_u32
    config.mapping_mode = "typo"
    expect_raises(Exception, /mapping mode/) { mapper.validate!(config) }
  end

  it "changes target policy against the same loaded reference index" do
    file = File.tempfile("adaptive-reference", ".fa")
    begin
      file.print(File.read("examples/reference.fa"))
      file.close
      config = sequence_config
      config.reference = file.path
      mapper = Adaptive::SequenceMapper.new(config)
      policy = Adaptive::BuiltinPolicy.new(config)
      # Rebuilding would now load a different contig and fail target validation.
      File.write(file.path, ">replacement\n#{"A" * 1000}\n")
      ["virus", "host"].each_with_index do |target, index|
        config.targets = [target]
        mapper.validate!(config)
        result = mapper.evaluate(replay_sequences.last, policy, Adaptive::Experiment.new,
          {} of String => String, channel: 1, read_id: "switch")
        result.decision.choice.should eq(index == 0 ? Adaptive::Choice::Accept : Adaptive::Choice::Reject)
        display_hit = result.display_hit.should_not be_nil
        display_hit.mapping.target_name.should eq("virus")
      end
      config.targets = ["missing"]
      expect_raises(Exception, /targets missing/) { mapper.validate!(config) }
    ensure
      file.close
      File.delete(file.path)
    end
  end

  it "matches replay decisions while leaving quota accounting to its caller" do
    config = sequence_config
    config.quota = 1
    mapper = Adaptive::SequenceMapper.new(config)
    policy = Adaptive::BuiltinPolicy.new(config)
    experiment = Adaptive::Experiment.new
    expected = File.read("examples/replay.jsonl").lines.map do |line|
      row = JSON.parse(line)
      result = mapper.evaluate(row["sequences"].as_a.map(&.as_s), policy, experiment,
        {} of String => String, channel: row["channel"].as_i, read_id: row["id"].as_s, samples: row["samples"].as_i)
      decision = result.decision
      if decision.choice.accept? && (group = decision.group)
        if experiment.reserve(group, decision.limit)
          experiment.acknowledge(group, true)
        else
          decision = Adaptive::Decision.new(Adaptive::Choice::Reject, "quota_full")
        end
      end
      {id: row["id"].as_s, choice: decision.choice.to_s, reason: decision.reason, hits: result.evidence.hits.size}.to_json
    end
    output = IO::Memory.new
    Adaptive.replay(config, policy, "examples/replay.jsonl", output)
    output.to_s.lines.should eq(expected)
    2.times do
      mapper.evaluate(replay_sequences.last, policy, experiment, {} of String => String, channel: 1, read_id: "preview")
    end
    experiment.confirmed["virus"].should eq(1)
    experiment.reserved["virus"].should eq(0)
  end

  it "preserves caller-owned memory and skips replay rows after a terminal decision" do
    file = File.tempfile("adaptive-replay", ".jsonl")
    begin
      ["one", "two", "one", "one", "two"].each do |id|
        file.puts({id: id, channel: 1, samples: 0, sequences: ["ACGT"]}.to_json)
      end
      file.close
      policy = SequenceMemoryPolicy.new
      output = IO::Memory.new
      Adaptive.replay(sequence_config, policy, file.path, output)
      policy.counts.should eq([1, 1, 2, 2])
      output.to_s.lines.map { |line| JSON.parse(line)["choice"].as_s }.should eq(["Continue", "Continue", "Accept", "Accept"])
    ensure
      file.close
      File.delete(file.path)
    end
  end

  it "shares an immutable index across parallel mapping calls" do
    mapper = Adaptive::SequenceMapper.new(sequence_config, threads: 2)
    sequences = replay_sequences.last
    context = Fiber::ExecutionContext::Parallel.new("sequence-spec", 4)
    replies = Channel(Adaptive::Evidence | Exception).new(16)
    16.times do |index|
      context.spawn do
        replies.send(mapper.map(sequences, channel: index + 1, read_id: "parallel-#{index}"))
      rescue ex
        replies.send(ex)
      end
    end
    ids = [] of String
    16.times do
      reply = replies.receive
      raise reply if reply.is_a?(Exception)
      ids << reply.read_id
      reply.hits.first.mapping.target_name.should eq("virus")
      reply.hits.first.mapping.mapq.should eq(60)
    end
    ids.uniq.size.should eq(16)
  end

  it "rejects missing or empty references and invalid evidence metadata" do
    config = sequence_config
    config.reference = "/missing/reference.fa"
    expect_raises(Exception, /missing reference/) { Adaptive::SequenceMapper.new(config) }
    file = File.tempfile("adaptive-empty", ".fa")
    begin
      file.close
      config.reference = file.path
      expect_raises(Exception, /index/) { Adaptive::SequenceMapper.new(config) }
    ensure
      File.delete(file.path)
    end
    mapper = Adaptive::SequenceMapper.new(sequence_config)
    expect_raises(Exception, /metadata/) { mapper.map(["A"], channel: 0, read_id: "bad") }
    expect_raises(Exception, /metadata/) { mapper.map(["A"], channel: 1, read_id: "") }
    expect_raises(Exception, /metadata/) { mapper.map(["A"], channel: 1, read_id: "bad", samples: -1) }
  end
end
