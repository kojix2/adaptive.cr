require "spec"
require "../src/adaptive/types"

private def minimap2_mapping(nm : Int32?) : Minimap2::Mapping
  Minimap2::Mapping.new(
    0, 10, Minimap2::Strand::Forward, "target", 10, 0, 10, 10, 10,
    60_u32, true, [] of Tuple(UInt32, UInt8), "", nm, nil, nil, nil
  )
end

describe Adaptive::Mapping do
  it "preserves a missing edit distance from minimap2" do
    Adaptive::Mapping.from_minimap2(minimap2_mapping(nil)).nm.should be_nil
  end

  it "preserves a computed edit distance from minimap2" do
    Adaptive::Mapping.from_minimap2(minimap2_mapping(2)).nm.should eq(2)
  end
end
