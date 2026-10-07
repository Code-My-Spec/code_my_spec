defmodule CodeMySpec.Agents.ACodingBriefNamesHowToReachWhatItNeedsTest do
  @moduledoc """
  The brief says where the framework reference is, and what is out of reach.

  Issue `7cb35065`. A coding agent needed the devops/observability README and
  the retired coder's prototype. It reached for `read_project_file`, was
  refused ("outside allowed directories"), and the main agent fetched both on
  its behalf -- which is the problem the issue names: a gap that blocks gets
  fixed, and one that is smoothly worked around stays invisible.

  Neither is a missing capability.

    * The framework reference, `priv/knowledge/devops/README.md`, is reachable
      with `read_knowledge({ path: "devops/README.md" })`, which coding carries.
      The agent reached for the wrong tool.
    * `git stash list` runs fine under the restricted shell; it is invisible to
      `git status` and `git diff`, so an agent looking for abandoned work with
      only those two will not find it.

  What is out of reach is a path outside the checkout -- `allowed_paths` is
  `[working_copy, spill_dir]`, and that is a sandbox rather than an oversight.
  The brief should say so, so the next agent says "this lives elsewhere" instead
  of reaching for a tool that will refuse it and leaving main to smooth it over.

  Asserted against the role's grants and against the file that exists, not
  against the wording, so a rewrite that keeps the instruction still passes and
  one that names a route coding does not have fails.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Agents.RoleBrief
  alias CodeMySpec.Agents.ToolSets

  @coding_brief RoleBrief.for(:coding)

  # The entry the refused read was for. It ships with the app.
  @devops_readme "priv/knowledge/devops/README.md"

  test "the premise still holds: the entry exists and read_knowledge is coding's" do
    assert File.exists?(@devops_readme),
           "the framework reference moved; this test's premise changed"

    assert "read_knowledge" in ToolSets.for_role(:coding),
           "coding no longer carries read_knowledge; the brief should say so instead"
  end

  test "the brief points at the framework reference" do
    assert @coding_brief =~ "read_knowledge",
           "a coding agent that needs the framework reference has to be told where it is"
  end

  test "the brief says a path outside the checkout is not reachable" do
    assert @coding_brief =~ ~r/outside|allowed_paths|checkout/i,
           "an agent has to know a path outside its copy is refused before it tries, " <>
             "or it reaches for the tool and then asks main to fetch it"
  end

  test "the brief names git stash for work that is not in status or diff" do
    assert @coding_brief =~ "git stash",
           "abandoned work is invisible to `git status` and `git diff` alone"
  end
end
