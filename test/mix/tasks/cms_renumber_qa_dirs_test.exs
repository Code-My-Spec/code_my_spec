defmodule Mix.Tasks.Cms.RenumberQaDirsTest do
  use ExUnit.Case, async: true

  alias Mix.Tasks.Cms.RenumberQaDirs

  test "an id directory is renamed to its story's number" do
    assert [%{action: :rename, from: "823", to: "686"}] =
             RenumberQaDirs.plan(["823"], %{823 => 686})
  end

  test "non-story directories and unknown ids are left alone" do
    plan = RenumberQaDirs.plan(["scripts", "999"], %{823 => 686})

    assert plan == [%{action: :unknown, from: "999"}]
  end

  test "a directory whose id equals its number needs nothing" do
    assert [%{action: :skip, from: "5"}] = RenumberQaDirs.plan(["5"], %{5 => 5})
  end

  test "a target that already exists and is not moving is refused" do
    plan = RenumberQaDirs.plan(["823", "686"], %{823 => 686})

    assert %{action: :collision, from: "823", to: "686"} in plan
    assert %{action: :unknown, from: "686"} in plan
  end

  test "a target vacated by another rename in the same pass is not a collision" do
    plan = RenumberQaDirs.plan(["5", "7"], %{5 => 7, 7 => 5})

    assert %{action: :rename, from: "5", to: "7"} in plan
    assert %{action: :rename, from: "7", to: "5"} in plan
  end
end
