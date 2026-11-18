require "spec"
require "../src/adaptive/types"

private def minimap2_mapping(nm : Int32?) : Minimap2::Mapping
  Minimap2::Mapping.new(
    0, 10, Minimap2::Strand::Forward, "target", 10, 0, 10, 10, 10,
    60_u32, true, [] of Tuple(UInt32, UInt8), "", nm, nil, nil, nil
  )
end

describe Adaptive::Evidence do
  it "filters hits in place, preserving the first hit when MAPQ is tied" do
    first = Adaptive::Hit.new(0, Adaptive::Mapping.new("first", mapq: 40_u32))
    tied = Adaptive::Hit.new(0, Adaptive::Mapping.new("tied", mapq: 40_u32))
    secondary = Adaptive::Hit.new(0, Adaptive::Mapping.new("secondary", mapq: 60_u32, is_primary: false))
    evidence = Adaptive::Evidence.new(1, "read", 0, ["ACGT"], [first, tied, secondary])
    evidence.representative_hit.should eq(secondary)
    evidence.representative_hit(40_u32, primary_only: true).should eq(first)
    evidence.representative_hit(41_u32, primary_only: true).should be_nil
    evidence.hits.size.should eq(3)
    Adaptive::Evidence.new(1, "empty", 0, [] of String, [] of Adaptive::Hit).representative_hit.should be_nil
  end
end

describe Adaptive::Mapping do
  it "preserves a missing edit distance from minimap2" do
    Adaptive::Mapping.from_minimap2(minimap2_mapping(nil)).nm.should be_nil
  end

  it "preserves a computed edit distance from minimap2" do
    Adaptive::Mapping.from_minimap2(minimap2_mapping(2)).nm.should eq(2)
  end
end
