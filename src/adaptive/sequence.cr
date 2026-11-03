require "./policy"

module Adaptive
  # Owns one immutable index. Each map call allocates its own native buffer,
  # so workers may share this mapper. Policies and read memory remain owned
  # by the coordinator; evaluate never reserves or acknowledges quota.
  class SequenceMapper
    @aligner : Minimap2::Aligner
    getter reference : String

    def initialize(config : Config, threads : Int32 = 1)
      config.validate_sequence!
      raise "invalid index thread count" unless (1..64).includes?(threads)
      @reference = File.expand_path(config.reference)
      @aligner = Minimap2::Aligner.new(reference, preset: "map-ont", cigar: true, threads: threads).single_index!
      raise "empty reference index" if @aligner.n_seq == 0
      @aligner.validate_targets!(config)
    end

    # Validate a changed policy/target selection without rebuilding the index.
    def validate!(config : Config) : Nil
      config.validate_sequence!
      raise "reference changed; create a new mapper" unless File.expand_path(config.reference) == reference
      @aligner.validate_targets!(config)
    end

    def map(sequences : Array(String), *, channel : Int32, read_id : String, samples : Int32 = 0,
            source : EvidenceSource = EvidenceSource::Sequence, basecalls : BasecallResult? = nil) : Evidence
      raise "invalid evidence metadata" if channel < 1 || read_id.empty? || samples < 0
      if basecalls
        basecalls.validate!
        raise ArgumentError.new("basecalls do not match evidence") unless basecalls.read_id == read_id && basecalls.sequences == sequences
      end
      hits = [] of Hit
      sequences.each_with_index do |sequence, segment|
        next if sequence.empty?
        @aligner.map(sequence).each { |mapping| hits << Hit.new(segment, mapping) }
      end
      Evidence.new(channel, read_id, samples, sequences.dup, hits, source, basecalls)
    end

    def evaluate(sequences : Array(String), policy : Policy, experiment : Experiment, memory : Hash(String, String), *,
                 channel : Int32, read_id : String, samples : Int32 = 0,
                 source : EvidenceSource = EvidenceSource::Sequence, basecalls : BasecallResult? = nil) : Evaluation
      evidence = map(sequences, channel: channel, read_id: read_id, samples: samples, source: source, basecalls: basecalls)
      decision = policy.decide(evidence, experiment, memory)
      Evaluation.new(evidence, decision, policy.representative_hit(evidence))
    end
  end
end
