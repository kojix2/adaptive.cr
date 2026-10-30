require "spec"
require "../examples/junction_policy"

it "finds a candidate junction only within one molecule" do
  index = Minimap2::Aligner.new("examples/reference.fa", preset: "map-ont", cigar: true)
  host = index.seq("host", 100, 900).should_not be_nil
  virus = index.seq("virus", 100, 900).should_not be_nil
  policy = JunctionPolicy.new
  [[host + virus], [host, virus]].each_with_index do |sequences, position|
    hits = [] of Adaptive::Hit
    sequences.each_with_index do |sequence, segment|
      index.map(sequence).each { |mapping| hits << Adaptive::Hit.new(segment, mapping) }
    end
    evidence = Adaptive::Evidence.new(1, "junction", 10000, sequences, hits)
    choice = policy.decide(evidence, Adaptive::Experiment.new, {} of String => String).choice
    choice.should eq(position == 0 ? Adaptive::Choice::Accept : Adaptive::Choice::Continue)
  end
end
