require "../src/adaptive/sequence"

# No bridge, Python interpreter or live connection is needed.
config = Adaptive::Config.from_json(%({"reference":"examples/reference.fa","targets":["virus"]}))
mapper = Adaptive::SequenceMapper.new(config)
policy = Adaptive::BuiltinPolicy.new(config)
experiment = Adaptive::Experiment.new
memory = {} of String => String
row = JSON.parse(File.read("examples/replay.jsonl").lines[1])
result = mapper.evaluate(row["sequences"].as_a.map(&.as_s), policy, experiment, memory,
  channel: 1, read_id: "sequence-example")
puts({choice: result.decision.choice.to_s, reason: result.decision.reason,
      target: result.decision.hit.try(&.mapping.target_name),
      display: result.display_hit.try(&.mapping.target_name)}.to_json)
