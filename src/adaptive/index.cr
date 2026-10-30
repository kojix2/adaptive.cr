# The pinned binding merges mapping lists, but does not recompute global MAPQ
# across index parts. Refuse multipart indices rather than trust those scores.
class Minimap2::Aligner
  def single_index! : self
    raise "multipart minimap2 index is unsupported; rebuild with a larger -I" unless @idx_parts.size == 1
    self
  end

  def validate_targets!(config : Adaptive::Config) : self
    single_index!
    if config.policy == "contig"
      missing = config.targets.reject do |name|
        Minimap2::LibMinimap2.mm_idx_name2id(@idx_parts.first, name) >= 0
      end
      raise "targets missing from reference: #{missing.join(", ")}" unless missing.empty?
    end
    self
  end
end
