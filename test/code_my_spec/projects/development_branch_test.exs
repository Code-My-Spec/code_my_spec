defmodule CodeMySpec.Projects.DevelopmentBranchTest do
  use ExUnit.Case, async: true
  alias CodeMySpec.Projects.Project
  alias CodeMySpec.Users.Scope

  test "main is the default; named development refs are accepted" do
    assert %Project{}.development_branch == "main"

    assert Project.changeset(
             %Project{},
             %{name: "Demo", development_branch: "team/develop"},
             %Scope{}
           ).valid?
  end

  test "rejects invalid Git branch refs and option-like values" do
    for branch <- [
          "",
          "-main",
          "../main",
          "a..b",
          "a@{b",
          "a.lock",
          "a//b",
          "main:",
          "a\\b",
          "a b",
          "a\nb"
        ] do
      refute Project.changeset(%Project{}, %{name: "Demo", development_branch: branch}, %Scope{}).valid?,
             branch
    end
  end
end
