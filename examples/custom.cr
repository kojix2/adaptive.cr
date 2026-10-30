require "../src/cli"
require "./junction_policy"

Adaptive.cli(->(_config : Adaptive::Config) { JunctionPolicy.new.as(Adaptive::Policy) })
