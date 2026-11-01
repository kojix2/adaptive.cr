require "spec"
require "../../src/gui/profile"

module NanoporeGUI
  describe Profile do
    it "starts in observe mode and preserves optional and custom policy settings" do
      Profile.initial.get("observe").as_bool.should be_true
      document = Profile.parse(%({"reference":"ref.fa","policy":"custom","quota":9,"observe":false}))
      document.get("quota").as_i.should eq(9)
      document.get("observe").as_bool.should be_false
      document.get("policy").as_s.should eq("custom")
    end

    it "rejects unknown settings just like the CLI" do
      expect_raises(JSON::SerializableError) { Profile.parse(%({"reference":"ref.fa","typo":1})) }
    end

    it "keeps validation, backend checks and offline replay separate from live mode" do
      Profile.arguments(:validate, 0, "").should eq(["--validate"])
      Profile.arguments(:backend, 0, "").should eq(["--check-backend"])
      Profile.arguments(:run, 0, "").should be_empty
      Profile.arguments(:run, 1, "a b.jsonl").should eq(["--replay=a b.jsonl"])
      expect_raises(Exception, /replay/) { Profile.arguments(:run, 1, "") }
    end
  end
end
