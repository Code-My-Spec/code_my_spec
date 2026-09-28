defmodule Mix.Tasks.Cms.RenumberQaDirsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Cms.RenumberQaDirs

  @dunning %{id: 823, number: 686, title: "Dunning emails go out"}
  @login %{id: 686, number: 540, title: "Login works"}

  test "a name that can only be an id moves to its story's number" do
    assert [%{action: :move, from: "823", to: "686"}] =
             RenumberQaDirs.plan([{"823", ""}], [@dunning])
  end

  test "a name that can only be a number stays" do
    assert [%{action: :stay, from: "686"}] =
             RenumberQaDirs.plan([{"686", ""}], [%{@dunning | id: 900}])
  end

  test "a name that is both a story's id and its number stays" do
    assert [%{action: :stay, from: "5"}] =
             RenumberQaDirs.plan([{"5", ""}], [%{id: 5, number: 5, title: "Five"}])
  end

  test "non-story directories and unknown names are left alone" do
    assert [%{action: :unknown, from: "999"}] =
             RenumberQaDirs.plan([{"scripts", ""}, {"999", ""}], [@dunning])
  end

  test "a move onto a directory whose owner is unsettled is not made" do
    plan =
      RenumberQaDirs.plan([{"823", ""}, {"686", "# Brief"}], [@dunning, @login])

    assert %{action: :blocked, from: "823", to: "686"} in plan
    assert %{action: :ambiguous, from: "686"} in plan
  end

  test "a move onto a directory already named by number merges into it" do
    plan = RenumberQaDirs.plan([{"823", ""}, {"686", ""}], [@dunning])

    assert %{action: :move, from: "823", to: "686"} in plan
    assert %{action: :stay, from: "686"} in plan
  end

  describe "a name that is one story's id and another's number" do
    test "moves when its heading names the story it is the id of" do
      plan = RenumberQaDirs.plan([{"686", "# QA Story 686: Login works"}], [@dunning, @login])
      assert plan == [%{action: :move, from: "686", to: "540"}]
    end

    test "stays when its heading names the story it is the number of" do
      plan =
        RenumberQaDirs.plan([{"686", "# Story 686 QA Brief: Dunning emails go out"}], [
          @dunning,
          @login
        ])

      assert plan == [%{action: :stay, from: "686"}]
    end

    test "is left alone when its heading names neither" do
      plan = RenumberQaDirs.plan([{"686", "# Brief"}], [@dunning, @login])
      assert plan == [%{action: :ambiguous, from: "686"}]
    end
  end
end
