require "spec"
require "../../src/gui/model"

module NanoporeGUI
  describe Document do
    it "edits a primary sample while preserving other samples and settings" do
      document = Document.new(%({"samples":[{"path":"one.fa","weight":2},{"path":"two.fa"}],"seed":123}))
      document.set_text(Field.new("samples.0.path", "Input"), "new path.fa")
      document.get("samples.0.path").as_s.should eq("new path.fa")
      document.get("samples.0.weight").as_i.should eq(2)
      document.get("samples.1.path").as_s.should eq("two.fa")
      document.get("seed").as_i.should eq(123)
    end

    it "reports invalid numeric fields without changing the document" do
      document = Document.new(%({"channels":1}))
      expect_raises(ArgumentError, /Channels/) do
        document.set_text(Field.new("channels", "Channels", :integer), "1.5")
      end
      document.get("channels").as_i.should eq(1)
    end

    it "converts optional paths and target lists to JSON values" do
      document = Document.new("{}")
      document.set_text(Field.new("output", "Output", :optional), "")
      document.set_text(Field.new("targets", "Targets", :list), "virus, other , ")
      document.get("output").raw.should be_nil
      document.get("targets").as_a.map(&.as_s).should eq(["virus", "other"])
    end

    it "rejects non-object configuration roots" do
      expect_raises(TypeCastError) { Document.new("[]") }
    end
  end
end
