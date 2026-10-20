defmodule CodeMySpec.Requirements.BandsTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.Requirements.Bands

  test "a story's work after components join is ready_for_qa and everything it unblocks" do
    assert Bands.post_story_names() ==
             MapSet.new(~w(ready_for_qa qa_complete story_promoted deploy))
  end

  test "the project's gates after stories join are the QA journey" do
    late = Bands.late_project_names()

    assert MapSet.member?(late, "qa_journey_plan")
    assert MapSet.member?(late, "qa_journey_execute")
    refute MapSet.member?(late, "work_dispatched")
    refute MapSet.member?(late, "personas_complete")
  end
end
