defmodule CodeMySpec.MainAgent.AFaultIsRaisedOnceTest do
  @moduledoc """
  A fault that persists is reported once, not once per call that notices it.

  Issue `57ba014e`. The faults these paths raise — the machinery serving no
  tools, a restart that changed nothing — last until a person deals with them,
  and the cadence keeps calling `check_machinery` and `restart_agent` in the
  meantime. Every one of those calls filed another copy: two from a single
  `check_machinery` followed by one `restart_agent`, and six identical issues
  from one QA measurement of the restart path.

  That defeats the criterion the path exists for. 3312 asks that a fault the
  main agent cannot act on gets raised and seen, and burying the first, real
  issue under repeats of itself is the opposite — at exactly the moment somebody
  is scanning the list for what is wrong.

  Open means unfinished. A dismissed or resolved issue is dealt with, so the
  same fault recurring afterwards is news and files again. That is the half
  worth testing: a dedupe keyed on "has ever existed" silently stops reporting a
  fault that came back, which is worse than the duplication it replaces.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.DevicesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.AgentsRepository
  alias CodeMySpec.Issues
  alias CodeMySpec.MainAgent
  alias CodeMySpec.WorkingCopies

  @fault "The machinery is serving no tools"

  # `tool_fault/1` reads `:machine` when every copy on the project is toolless
  # and has an agent — an empty tool list is only a fault for a copy that has
  # somebody on it, and `nil` (never reported) is not a fault at all.
  defp a_project_whose_machine_serves_nothing(scope) do
    {:ok, copy} =
      WorkingCopies.issue(scope, nil, label: "a checkout", device: device_fixture(scope))

    :ok = WorkingCopies.record_machine_tools(copy, [])

    {:ok, _agent} =
      AgentsRepository.create_agent(scope, %{
        provider: "anthropic",
        engine: :alloy,
        role: "coding",
        status: :running,
        working_copy: "/tmp/toolless-#{System.unique_integer([:positive])}",
        working_copy_id: copy.id
      })

    %{scope | active_working_copy_id: copy.id}
  end

  defp raised(scope) do
    scope
    |> Issues.list_issues()
    |> Enum.count(&(&1.title == @fault))
  end

  setup do
    scope = full_scope_fixture()
    %{scope: a_project_whose_machine_serves_nothing(scope)}
  end

  test "the second look does not file a second copy", %{scope: scope} do
    MainAgent.check_machinery(scope)

    assert raised(scope) == 1,
           "the premise failed: looking at a machine serving no tools raised nothing"

    MainAgent.check_machinery(scope)
    MainAgent.check_machinery(scope)

    assert raised(scope) == 1, """
    Three looks, three issues. The cadence calls check_machinery repeatedly
    while the fault persists, so the list fills with copies of the one thing
    somebody needed to read (57ba014e).
    """
  end

  test "and a fault that comes back after being dealt with is news again", %{scope: scope} do
    MainAgent.check_machinery(scope)

    [issue] = scope |> Issues.list_issues() |> Enum.filter(&(&1.title == @fault))
    {:ok, _} = Issues.dismiss_issue(scope, issue, "dealt with")

    MainAgent.check_machinery(scope)

    assert raised(scope) == 2, """
    The fault recurred after somebody finished with the last one, and nothing
    was filed. A dedupe keyed on "has ever existed" stops reporting a fault that
    came back — worse than the duplication it replaces.
    """
  end
end
