defmodule CodeMySpec.Analysis.TheRunningIndicatorIsAboutThisCheckoutTest do
  @moduledoc """
  "Analyzers are running" has to mean *this* agent's analyzers.

  `running_since/1` scopes to the working copy the scope names, and
  `scope_to_harness/2` drops the filter entirely when it names none. That is
  exactly the web UI's case — a person browsing a conversation has no checkout
  selected — so the indicator asked "is any copy of this project running
  anything". With several checkouts on one project the answer is almost always
  yes, and the spinner never went out.

  John, watching it: "it's constantly saying analyzers are running. Pretty sure
  that's not true anymore." It was true, about somebody else's tree.

  Tested at the repository rather than through the LiveView because the defect
  is in what the query answers, not in what the template does with it.
  """
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures

  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.WorkingCopies

  setup do
    scope = full_scope_fixture()

    {:ok, mine} = WorkingCopies.issue(scope, nil, label: "mine", device: device_fixture(scope))

    {:ok, theirs} =
      WorkingCopies.issue(scope, nil, label: "theirs", device: device_fixture(scope))

    %{scope: scope, mine: mine, theirs: theirs}
  end

  # Through the scope, because that is where `start_run/2` reads it from — it
  # overrides any `working_copy_id` in the attrs, so a fixture that passed one
  # there would file every run against the same copy and prove nothing.
  defp running_run(scope, copy_id, source) do
    CodeMySpec.AnalysisFixtures.analysis_run_fixture(at(scope, copy_id), %{source: source})
  end

  defp at(scope, copy_id), do: %Scope{scope | active_working_copy_id: copy_id}

  test "another checkout's sweep is not this one's", ctx do
    running_run(ctx.scope, ctx.theirs.id, "spex")

    assert RunsRepository.running_since(at(ctx.scope, ctx.mine.id)) == %{},
           """
           A sweep on another checkout showed as this agent's. That is the spinner
           that never goes out: with several copies on one project, at least one is
           always mid-run.
           """
  end

  test "this checkout's sweep is this one's", ctx do
    running_run(ctx.scope, ctx.mine.id, "spex")

    assert Map.has_key?(RunsRepository.running_since(at(ctx.scope, ctx.mine.id)), "spex")
  end

  # The unscoped answer is still available and still means what it says — it is
  # what an operator thread with no agent gets, and the project view wants it.
  # Pinned so the fix is understood as "ask the right question" rather than "the
  # query was wrong".
  test "a scope naming no checkout still sees the project", ctx do
    running_run(ctx.scope, ctx.theirs.id, "spex")

    assert Map.has_key?(
             RunsRepository.running_since(at(ctx.scope, nil)),
             "spex"
           )
  end
end
