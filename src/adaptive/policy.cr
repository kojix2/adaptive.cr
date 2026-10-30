require "digest/sha256"
require "./types"

module Adaptive
  abstract class Policy
    # Runs on the coordinator. Keep this short; expensive feature extraction
    # belongs in worker code. memory is private to the current read generation.
    abstract def decide(read : Evidence, experiment : Experiment, memory : Hash(String, String)) : Decision
  end

  class BuiltinPolicy < Policy
    def initialize(@config : Config)
      raise "custom policy requires a custom executable" if @config.policy == "custom"
    end

    def decide(read : Evidence, experiment : Experiment, memory : Hash(String, String)) : Decision
      return Decision.new(Choice::Accept, "accept_all") if @config.policy == "all"
      return Decision.new(Choice::Continue, "short_sequence") if read.sequences.sum(&.size) < @config.min_bases
      group = nil
      case @config.policy
      when "contig"
        hit = read.hits.find { |item| item.mapping.mapq >= @config.mapq && @config.targets.includes?(item.mapping.target_name) }
        group = hit.mapping.target_name if hit
      when "motif"
        reverse = @config.motif.reverse.tr("ACGT", "TGCA")
        group = "motif" if read.sequences.any? { |sequence| sequence.includes?(@config.motif) || sequence.includes?(reverse) }
      end
      return Decision.new(Choice::Accept, "target", group, @config.quota) if group
      return Decision.new(Choice::Accept, "background") if background?(read.read_id)
      # Low-confidence mapping is not evidence for rejecting the molecule.
      if @config.policy == "contig" && read.hits.none? { |item| item.mapping.mapq >= @config.mapq }
        return Decision.new(Choice::Continue, "uncertain_mapping")
      end
      Decision.new(Choice::Reject, "non_target")
    end

    private def background?(id : String) : Bool
      digest = Digest::SHA256.hexdigest("#{@config.seed}:#{id}")[0, 8].to_u64(16)
      digest / 4294967296.0 < @config.background_fraction
    end
  end
end
