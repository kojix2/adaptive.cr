require "spec"
require "../src/adaptive/policy"

private def policy_config(mode = "any")
  Adaptive::Config.from_json({reference: "examples/reference.fa", targets: ["virus"],
                              mapping_mode: mode, min_bases: 100}.to_json)
end

private def policy_hit(name, mapq = 60_u32, primary = true, segment = 0)
  Adaptive::Hit.new(segment, Adaptive::Mapping.new(name, mapq, is_primary: primary))
end

private def policy_read(hits = [] of Adaptive::Hit, sequences = ["A" * 300])
  Adaptive::Evidence.new(1, "read", 1000, sequences, hits)
end

private def policy_decide(config, read)
  Adaptive::BuiltinPolicy.new(config).decide(read, Adaptive::Experiment.new, {} of String => String)
end

describe Adaptive::BuiltinPolicy do
  it "preserves any-hit live selection and primary-only sandbox selection" do
    target = policy_hit("virus", 40_u32, false)
    host = policy_hit("host")
    read = policy_read([host, target])
    live = policy_decide(policy_config, read)
    live.choice.should eq(Adaptive::Choice::Accept)
    live.hit.should eq(target)
    sandbox = policy_decide(policy_config("primary"), read)
    sandbox.choice.should eq(Adaptive::Choice::Reject)
    sandbox.hit.should eq(host)
    # Secondary and supplementary are both non-primary in the binding.
    policy_decide(policy_config("primary"), policy_read([target])).choice.should eq(Adaptive::Choice::Continue)
    policy_decide(policy_config, policy_read([target])).choice.should eq(Adaptive::Choice::Accept)
  end

  it "selects the highest MAPQ primary across segments for sandbox compatibility" do
    target = policy_hit("virus", 40_u32, true, 0)
    host = policy_hit("host", 60_u32, true, 1)
    read = policy_read([target, host], ["A" * 150, "C" * 150])
    policy_decide(policy_config, read).choice.should eq(Adaptive::Choice::Accept)
    policy_decide(policy_config("primary"), read).choice.should eq(Adaptive::Choice::Reject)
    read.representative_hit.should eq(host)
  end

  it "keeps the display hit separate from the target that justified acceptance" do
    host = policy_hit("host")
    target = policy_hit("virus", 40_u32)
    read = policy_read([host, target])
    policy = Adaptive::BuiltinPolicy.new(policy_config)
    policy.representative_hit(read).should eq(host)
    policy.decide(read, Adaptive::Experiment.new, {} of String => String).hit.should eq(target)
  end

  it "continues on short, unmapped or low MAPQ reads and accepts at the threshold" do
    ["any", "primary"].each do |mode|
      config = policy_config(mode)
      policy_decide(config, policy_read([policy_hit("virus")], ["A" * 99])).reason.should eq("short_sequence")
      policy_decide(config, policy_read).reason.should eq("uncertain_mapping")
      policy_decide(config, policy_read([policy_hit("virus", 19_u32)])).choice.should eq(Adaptive::Choice::Continue)
      policy_decide(config, policy_read([policy_hit("virus", 20_u32)], ["A" * 100])).choice.should eq(Adaptive::Choice::Accept)
    end
  end

  it "preserves background sampling precedence and returns quota without reserving it" do
    config = policy_config
    config.background_fraction = 1.0
    policy_decide(config, policy_read).reason.should eq("background")
    policy_decide(config, policy_read([] of Adaptive::Hit, ["A"])).reason.should eq("short_sequence")
    config.quota = 2
    experiment = Adaptive::Experiment.new
    policy = Adaptive::BuiltinPolicy.new(config)
    2.times do
      decision = policy.decide(policy_read([policy_hit("virus")]), experiment, {} of String => String)
      decision.group.should eq("virus")
      decision.limit.should eq(2)
      decision.reason.should eq("target")
    end
    experiment.reserved.should be_empty
    experiment.confirmed.should be_empty
  end
end
