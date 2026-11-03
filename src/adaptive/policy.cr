require "digest/sha256"
require "./types"

module Adaptive
  abstract class Policy
    # Runs on the coordinator. Keep this short; expensive feature extraction
    # belongs in worker code. memory is private to the current read generation.
    abstract def decide(read : Evidence, experiment : Experiment, memory : Hash(String, String)) : Decision

    def representative_hit(read : Evidence) : Hit?
      read.representative_hit
    end
  end

  class BuiltinPolicy < Policy
    def initialize(@config : Config)
      raise "custom policy requires a custom executable" if @config.policy == "custom"
    end

    def decide(read : Evidence, experiment : Experiment, memory : Hash(String, String)) : Decision
      return Decision.new(Choice::Accept, "accept_all") if @config.policy == "all"
      return Decision.new(Choice::Continue, "short_sequence") if read.sequences.sum(&.size) < @config.min_bases
      group = nil
      hit : Hit? = nil
      case @config.policy
      when "contig"
        hit = if @config.mapping_mode == "primary"
                representative_hit(read)
              else
                read.hits.find { |item| item.mapping.mapq >= @config.mapq && @config.targets.includes?(item.mapping.target_name) }
              end
        group = hit.mapping.target_name if hit && @config.targets.includes?(hit.mapping.target_name)
      when "motif"
        reverse = @config.motif.reverse.tr("ACGT", "TGCA")
        group = "motif" if read.sequences.any? { |sequence| sequence.includes?(@config.motif) || sequence.includes?(reverse) }
      end
      return Decision.new(Choice::Accept, "target", group, @config.quota, hit: @config.policy == "contig" ? hit : nil) if group
      return Decision.new(Choice::Accept, "background") if background?(read.read_id)
      # Low-confidence mapping is not evidence for rejecting the molecule.
      if @config.policy == "contig" && representative_hit(read).nil?
        return Decision.new(Choice::Continue, "uncertain_mapping")
      end
      Decision.new(Choice::Reject, "non_target", hit: @config.policy == "contig" ? representative_hit(read) : nil)
    end

    def representative_hit(read : Evidence) : Hit?
      read.representative_hit(@config.mapq, primary_only: @config.mapping_mode == "primary")
    end

    private def background?(id : String) : Bool
      digest = Digest::SHA256.hexdigest("#{@config.seed}:#{id}")[0, 8].to_u64(16)
      digest / 4294967296.0 < @config.background_fraction
    end
  end
end
