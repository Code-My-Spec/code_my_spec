defmodule CodeMySpec.Requirements.BandsTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Requirements.Bands

  test "the project's gates after stories join are the QA journey" do
    late = Bands.late_project_names()

    assert MapSet.member?(late, "qa_journey_plan")
    assert MapSet.member?(late, "qa_journey_execute")
    refute MapSet.member?(late, "work_dispatched")
    refute MapSet.member?(late, "personas_complete")
  end

  test "a story's steps run prerequisites first" do
    steps = Bands.story_step_names()
    position = &Enum.find_index(steps, fn name -> name == &1 end)

    assert hd(steps) == "component_linked"
    assert position.("three_amigos_complete") < position.("bdd_specs_exist")
    assert position.("bdd_specs_exist") < position.("ready_for_qa")
    assert position.("ready_for_qa") < position.("qa_complete")
    assert position.("story_promoted") < position.("deploy")
  end
end
