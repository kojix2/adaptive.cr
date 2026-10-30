require "spec"
require "../src/adaptive/types"

it "refuses multipart minimap2 indices before trusting MAPQ" do
  index_options = Minimap2::LibMinimap2::MmIdxoptT.new
  map_options = Minimap2::LibMinimap2::MmMapoptT.new
  Minimap2::LibMinimap2.mm_set_opt(Pointer(LibC::Char).null, pointerof(index_options), pointerof(map_options))
  Minimap2::LibMinimap2.mm_set_opt("map-ont", pointerof(index_options), pointerof(map_options))
  index_options.batch_size = 10000_i64
  index = Minimap2::Aligner.new(index_options, map_options, 1, "examples/reference.fa", nil)
  expect_raises(Exception, /multipart/) { index.single_index! }
end

it "validates target names against the loaded index" do
  index = Minimap2::Aligner.new("examples/reference.fa", preset: "map-ont")
  config = Adaptive::Config.from_json(%({"reference":"examples/reference.fa","targets":["virus"]}))
  index.validate_targets!(config).should eq(index)
  config.targets = ["misspelled-virus"]
  expect_raises(Exception, /targets missing/) { index.validate_targets!(config) }
end

it "rejects unknown configuration keys" do
  expect_raises(JSON::SerializableError, /unknown/i) do
    Adaptive::Config.from_json(%({"reference":"examples/reference.fa","obeserve":false}))
  end
end
