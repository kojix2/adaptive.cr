require "./policy"

module Adaptive
  # Offline policy replay from JSONL sequences. Deliberately separate from
  # live signal input: synthetic sequences cannot be mistaken for basecalls.
  def self.replay(config : Config, policy : Policy, path : String, output : IO = STDOUT) : Nil
    aligner = Minimap2::Aligner.new(config.reference, preset: "map-ont", cigar: true).validate_targets!(config)
    experiment = Experiment.new
    memory = {} of String => Hash(String, String)
    terminal = Set(String).new
    File.each_line(path) do |line|
      row = JSON.parse(line)
      id = row["id"].as_s
      next if terminal.includes?(id)
      sequences = row["sequences"].as_a.map(&.as_s)
      hits = [] of Hit
      sequences.each_with_index do |sequence, index|
        aligner.map(sequence).each { |mapping| hits << Hit.new(index, mapping) } unless sequence.empty?
      end
      evidence = Evidence.new(row["channel"].as_i, id, row["samples"].as_i, sequences, hits)
      read_memory = memory[id] ||= {} of String => String
      decision = policy.decide(evidence, experiment, read_memory)
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
      output.puts({id: id, choice: decision.choice.to_s, reason: decision.reason, hits: hits.size}.to_json)
    end
  end
end
