require "spec"
require "../src/adaptive/engine"
require "../src/adaptive/replay"

class FixedPolicy < Adaptive::Policy
  def initialize(@decision : Adaptive::Decision)
  end

  def decide(read : Adaptive::Evidence, experiment : Adaptive::Experiment, memory : Hash(String, String)) : Adaptive::Decision
    @decision
  end
end

private def harness(decision = Adaptive::Decision.new(Adaptive::Choice::Accept, "test"), policy : Adaptive::Policy? = nil, &)
  config = Adaptive::Config.from_json(%({"reference":"examples/reference.fa","targets":["host"],"first_channel":1,"last_channel":2,"min_samples":100,"step_samples":100,"max_samples":400,"observe":false}))
  file = File.tempfile("adaptive-spec")
  path = file.path
  file.close
  File.delete(path)
  log = Adaptive::EventLog.new(path)
  jobs = [] of Adaptive::Job
  sent = [] of Tuple(Int32, String, Adaptive::Decision, String)
  submit = ->(job : Adaptive::Job) { jobs << job; true }
  sender = ->(channel : Int32, id : String, value : Adaptive::Decision, action_id : String) { sent << {channel, id, value, action_id}; nil }
  engine = Adaptive::Engine.new(config, policy || FixedPolicy.new(decision), log, submit, sender, [0.0, 1.0], [0.1, 0.2], 5000.0)
  begin
    yield engine, config, jobs, sent
  ensure
    log.close
    File.delete(path)
  end
end

class SlowRejectPolicy < Adaptive::Policy
  def decide(read : Adaptive::Evidence, experiment : Adaptive::Experiment, memory : Hash(String, String)) : Adaptive::Decision
    sleep 120.milliseconds
    Adaptive::Decision.new(Adaptive::Choice::Reject, "slow_rejection")
  end
end

private def feed(engine, channel = 1, id = "read", from = 0_u64, count = 100_u64)
  engine.ingest(channel, id, 0_u64, from, count, Bytes.new(count.to_i * 2))
end

private def answer(job)
  Adaptive::Result.new(job, Adaptive::Evidence.new(job.channel, job.read_id, job.signal.size // 2, ["ACGT"], [] of Adaptive::Hit))
end

describe Adaptive::Engine do
  it "preserves a molecule when a custom policy crosses the deadline" do
    harness(policy: SlowRejectPolicy.new) do |engine, config, jobs, sent|
      config.deadline_ms = 100
      feed(engine)
      engine.advance
      engine.complete(answer(jobs[0]))
      sent[0][2].choice.should eq(Adaptive::Choice::Accept)
      sent[0][2].reason.should eq("decision_deadline")
    end
  end
  it "accumulates prefixes and keeps one job in flight per read" do
    harness(Adaptive::Decision.new(Adaptive::Choice::Continue, "more")) do |engine, _, jobs, _|
      feed(engine)
      engine.advance
      feed(engine, from: 100_u64)
      engine.advance
      jobs.size.should eq(1)
      jobs[0].signal.size.should eq(200)
      engine.complete(answer(jobs[0]))
      engine.advance
      jobs.size.should eq(2)
      jobs[1].signal.size.should eq(400)
      jobs[1].scale.should eq(0.1)
    end
  end
  it "discards results belonging to a previous read generation" do
    harness do |engine, _, jobs, sent|
      feed(engine)
      engine.advance
      feed(engine, id: "successor")
      engine.complete(answer(jobs[0]))
      sent.should be_empty
      engine.inflight_bytes.should eq(0)
    end
  end
  it "fails open on a missing prefix, overlap or malformed stream" do
    harness do |engine, _, _, sent|
      feed(engine, from: 1_u64)
      sent[0][2].choice.should eq(Adaptive::Choice::Accept)
      sent[0][2].reason.should eq("signal_gap_or_overlap")
      engine.buffered_bytes.should eq(0)
      expect_raises(Exception, /payload/) { engine.ingest(1, "x", 0_u64, 0_u64, 100_u64, Bytes[1]) }
    end
  end
  it "does not apply a late rejection even before the timer tick" do
    harness(Adaptive::Decision.new(Adaptive::Choice::Reject, "reject")) do |engine, config, jobs, sent|
      config.deadline_ms = 1
      feed(engine)
      engine.advance
      sleep 3.milliseconds
      engine.complete(answer(jobs[0]))
      sent[0][2].choice.should eq(Adaptive::Choice::Accept)
      sent[0][2].reason.should eq("decision_deadline")
    end
  end
  it "reserves quotas atomically and releases failed acknowledgments" do
    decision = Adaptive::Decision.new(Adaptive::Choice::Accept, "target", "virus", 1)
    harness(decision) do |engine, _, jobs, sent|
      feed(engine)
      feed(engine, channel: 2, id: "other")
      engine.advance
      jobs.each { |job| engine.complete(answer(job)) }
      sent.map(&.[2].choice).should eq([Adaptive::Choice::Accept, Adaptive::Choice::Reject])
      engine.experiment.reserved["virus"].should eq(1)
      engine.acknowledge(sent[0][3], 1)
      engine.experiment.reserved["virus"].should eq(0)
      engine.experiment.confirmed["virus"].should eq(0)
    end
  end
  it "counts successful actions only once" do
    harness(Adaptive::Decision.new(Adaptive::Choice::Accept, "target", "virus", 1)) do |engine, _, jobs, sent|
      feed(engine)
      engine.advance
      engine.complete(answer(jobs[0]))
      2.times { engine.acknowledge(sent[0][3], 0) }
      engine.experiment.confirmed["virus"].should eq(1)
      engine.complete(answer(jobs[0]))
      engine.inflight_bytes.should eq(0)
      sent.size.should eq(1)
    end
  end
  it "emits no device commands in observation mode" do
    harness do |engine, config, jobs, sent|
      config.observe = true
      feed(engine)
      engine.advance
      engine.complete(answer(jobs[0]))
      sent.should be_empty
    end
  end
  it "releases prefix storage after a signal budget fallback" do
    harness do |engine, _, _, sent|
      feed(engine, count: 300_u64)
      feed(engine, from: 300_u64, count: 200_u64)
      engine.buffered_bytes.should eq(0)
      engine.states[1].signal.size.should eq(0)
      sent[0][2].reason.should eq("signal_budget")
    end
  end
  it "accepts on basecaller failure and stops on unacknowledged actions" do
    harness do |engine, config, jobs, sent|
      config.ack_timeout_ms = 1
      feed(engine)
      engine.advance
      engine.complete(Adaptive::Result.new(jobs[0], error: "backend lost"))
      sent[0][2].choice.should eq(Adaptive::Choice::Accept)
      sleep 3.milliseconds
      expect_raises(Exception, /acknowledgment timeout/) { engine.advance }
    end
  end

  it "does not confirm a late acknowledgment or release its reservation" do
    harness(Adaptive::Decision.new(Adaptive::Choice::Accept, "target", "virus", 1)) do |engine, config, jobs, sent|
      config.ack_timeout_ms = 10
      feed(engine)
      engine.advance
      engine.complete(answer(jobs[0]))
      sleep 20.milliseconds
      expect_raises(Exception, /acknowledgment timeout/) { engine.acknowledge(sent[0][3], 0) }
      engine.pending_actions.should eq(1)
      engine.experiment.confirmed["virus"].should eq(0)
      engine.experiment.reserved["virus"].should eq(1)
    end
  end

  it "stops before a completed worker can send another action after an acknowledgment timeout" do
    harness(Adaptive::Decision.new(Adaptive::Choice::Reject, "non_target")) do |engine, config, jobs, sent|
      config.ack_timeout_ms = 10
      feed(engine)
      feed(engine, channel: 2, id: "other")
      engine.advance
      engine.complete(answer(jobs[0]))
      sleep 20.milliseconds
      expect_raises(Exception, /acknowledgment timeout/) { engine.complete(answer(jobs[1])) }
      sent.size.should eq(1)
    end
  end

  it "checks acknowledgment timeouts before issuing deadline fallback actions" do
    harness do |engine, config, jobs, sent|
      config.ack_timeout_ms = 10
      feed(engine)
      engine.advance
      engine.complete(answer(jobs[0]))
      feed(engine, channel: 2, id: "other")
      config.deadline_ms = 1
      sleep 20.milliseconds
      expect_raises(Exception, /acknowledgment timeout/) { engine.advance }
      sent.size.should eq(1)
    end
  end

  it "rechecks acknowledgment deadlines after a slow custom policy returns" do
    harness(policy: SlowRejectPolicy.new) do |engine, config, jobs, sent|
      config.ack_timeout_ms = 50
      feed(engine)
      feed(engine, channel: 2, id: "other")
      engine.advance
      engine.complete(answer(jobs[0]))
      expect_raises(Exception, /acknowledgment timeout/) { engine.complete(answer(jobs[1])) }
      sent.size.should eq(1)
    end
  end
end

describe "real minimap2 policy replay" do
  it "maps host and virus sequences and enforces a quota" do
    config = Adaptive::Config.from_json(File.read("examples/live.json"))
    output = IO::Memory.new
    Adaptive.replay(config, Adaptive::BuiltinPolicy.new(config), "examples/replay.jsonl", output)
    rows = output.to_s.lines.map { |line| JSON.parse(line) }
    rows.map(&.["choice"].as_s).should eq(["Reject", "Accept", "Reject"])
    rows.last["reason"].as_s.should eq("quota_full")
  end
  it "matches reverse complement motifs and does not join split molecules" do
    config = Adaptive::Config.from_json(%({"reference":"examples/reference.fa","policy":"motif","motif":"AACC","min_bases":4}))
    policy = Adaptive::BuiltinPolicy.new(config)
    experiment = Adaptive::Experiment.new
    memory = {} of String => String
    hit = Adaptive::Evidence.new(1, "id", 100, ["GGTT"], [] of Adaptive::Hit)
    policy.decide(hit, experiment, memory).choice.should eq(Adaptive::Choice::Accept)
    split = Adaptive::Evidence.new(1, "id", 100, ["AA", "CC"], [] of Adaptive::Hit)
    policy.decide(split, experiment, memory).choice.should eq(Adaptive::Choice::Reject)
  end
end
