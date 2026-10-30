require "../src/adaptive/policy"

# Illustrative candidate enrichment, NOT a validated structural-variant caller.
class JunctionPolicy < Adaptive::Policy
  def decide(read : Adaptive::Evidence, experiment : Adaptive::Experiment, memory : Hash(String, String)) : Adaptive::Decision
    memory["evaluations"] = ((memory["evaluations"]? || "0").to_i + 1).to_s
    # Split basecalls are separate molecules; never join their evidence.
    read.hits.group_by(&.segment).each_value do |hits|
      confident = hits.select { |hit| hit.mapping.mapq >= 20 && hit.mapping.block_len >= 100 }
      host = confident.select { |hit| hit.mapping.target_name == "host" }
      virus = confident.select { |hit| hit.mapping.target_name == "virus" }
      host.each do |left|
        virus.each do |right|
          first, second = [left.mapping, right.mapping].sort_by(&.query_start)
          gap = second.query_start - first.query_end
          if (-50..200).includes?(gap)
            return Adaptive::Decision.new(Adaptive::Choice::Accept, "candidate_host_virus", "junction", 100)
          end
        end
      end
    end
    Adaptive::Decision.new(Adaptive::Choice::Continue, "need_more_evidence")
  end
end
