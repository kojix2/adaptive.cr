require "./sequence"

module Adaptive
  # Offline policy replay from JSONL sequences. Deliberately separate from
  # live signal input: synthetic sequences cannot be mistaken for basecalls.
  def self.replay(config : Config, policy : Policy, path : String, output : IO = STDOUT) : Nil
    mapper = SequenceMapper.new(config)
    experiment = Experiment.new
    memory = {} of String => Hash(String, String)
    terminal = Set(String).new
    File.each_line(path) do |line|
      row = JSON.parse(line)
      id = row["id"].as_s
      next if terminal.includes?(id)
      sequences = row["sequences"].as_a.map(&.as_s)
      read_memory = memory[id] ||= {} of String => String
      evaluation = mapper.evaluate(sequences, policy, experiment, read_memory,
        channel: row["channel"].as_i, read_id: id, samples: row["samples"].as_i)
      decision = evaluation.decision
      if decision.choice.accept?
        if group = decision.group
          if experiment.reserve(group, decision.limit)
            experiment.acknowledge(group, true)
          else
            decision = Decision.new(Choice::Reject, "quota_full")
          end
        end
      end
      terminal.add(id) unless decision.choice.continue?
      output.puts({id: id, choice: decision.choice.to_s, reason: decision.reason, hits: evaluation.evidence.hits.size}.to_json)
    end
  end
end
