defmodule CodeMySpec.MainAgent.MachineryAnswersWithoutACheckoutTest do
  @moduledoc """
  `check_machinery` degrades when the caller named a project and no checkout,
  rather than crashing.

  Issue `b27c54f1`, found during story 1015's QA. `MachineryRepository.latest_run/2`
  compared `working_copy_id` with `scope.active_working_copy_id` and Ecto refuses
  to compare a column with `nil` — so the whole report raised:

      comparing `r.working_copy_id` with `nil` is forbidden as it is unsafe

  It is reachable rather than theoretical: `Plugs.ProjectScopeOverride` documents
  `X-Project-ID` alone as a supported way to reach `/mcp/harness` ("still
  accepted, for callers that only have one"), and that is precisely what leaves
  `active_working_copy_id` nil.

  The crash is the wrong failure for this tool in particular. `check_machinery`
  exists to answer "is it the agent or the machine", so an absent field taking
  the entire answer down leaves the caller with less than it had before it
  asked — and the harness, tools, preview and machine sections never needed a
  checkout at all.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.MainAgent

  test "a scope with a project and no checkout still gets a report" do
    scope = full_scope_fixture()
    without_a_checkout = %{scope | active_working_copy_id: nil}

    machinery = MainAgent.check_machinery(without_a_checkout)

    assert %{analyzers: analyzers} = machinery, """
    The report raised instead of answering. Any caller that authenticates by
    project rather than by a specific harness hits this, and the tool it breaks
    is the one whose whole job is telling a machine problem from an agent
    problem (b27c54f1).
    """

    assert analyzers != [], "the analyzers section vanished rather than reporting what it knows"

    assert Enum.all?(analyzers, &(&1.state == :never_run)), """
    A checkout-less scope has no analyzer runs to report, and `:never_run` is
    what `state_of/2` already answers for a missing run. Anything else would be
    inventing a verdict from an absence.
    """
  end

  test "and a scope that has one still reports against it" do
    scope = full_scope_fixture()

    machinery = MainAgent.check_machinery(scope)

    assert %{analyzers: analyzers} = machinery

    assert analyzers != [], """
    Refusing to crash is only right if the ordinary case still answers. Without
    this the test above would pass on a function that reports nothing for
    everybody.
    """
  end
end
