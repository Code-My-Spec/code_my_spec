defmodule CodeMySpec.Issues.ATenantIsNotGatedOnTheVendorsBugsTest do
  @moduledoc """
  A project's issue gates count the project's own issues.

  `vendor_lookup/2` already states half of this rule — "the vendor reaches a
  framework issue in any project, because that is where framework issues live" —
  and `only_framework/1` refuses a tenant those same rows. So a tenant can
  neither read nor resolve a framework issue, and `issues_resolved` counted them
  anyway. A gate whose passing state depends on somebody else's repository is a
  wall.

  Broken Oaths on 2026-09-08: 22 of the 33 issues holding `issues_resolved` were
  `:framework` — `tool_docs ignores requested tool names`, `Task tools
  unavailable without session owner`, `list_tasks cannot identify the active
  agent`. A coding agent held that task for two hours and resolved none of them.
  In fifty minutes it made four tool calls. One of the 22 was a report of this
  exact defect, filed 09-06 and still open.

  `attribute_to_story/3` makes the same argument one level down: a framework
  finding is "about the tooling around the work, not the work". This is that,
  applied to the project gate as well as the story gate.
  """
  use CodeMySpecTest.DataCase, async: false

  alias CodeMySpec.Issues

  import CodeMySpec.IssuesFixtures
  import CodeMySpec.UsersFixtures

  setup do
    %{scope: full_scope_fixture()}
  end

  defp accepted(scope, attrs) do
    issue_fixture(scope, Map.merge(%{status: :accepted, severity: :high}, attrs))
  end

  test "a framework issue does not hold a tenant's gate", %{scope: scope} do
    accepted(scope, %{scope: :framework, title: "tool_docs ignores requested tool names"})

    assert Issues.list_by_status_and_min_severity(scope, :accepted, :medium) == [],
           "a tenant cannot read or resolve this issue, so it cannot be asked to clear it"
  end

  test "the project's own issues still hold it", %{scope: scope} do
    accepted(scope, %{scope: :app, title: "the game crashes on turn end"})

    assert [issue] = Issues.list_by_status_and_min_severity(scope, :accepted, :medium)
    assert issue.scope == :app
  end

  test "qa and docs findings still count", %{scope: scope} do
    accepted(scope, %{scope: :qa, title: "the QA seed leaves no city"})
    accepted(scope, %{scope: :docs, title: "the README names a removed flag"})

    scopes =
      scope
      |> Issues.list_by_status_and_min_severity(:accepted, :medium)
      |> Enum.map(& &1.scope)
      |> Enum.sort()

    assert scopes == [:docs, :qa],
           "only :framework belongs to somebody else; the rest are this project's"
  end

  # The other direction, and the reason this is not a blanket exclusion. In the
  # CodeMySpec project a framework issue *is* an app issue, and `issues_resolved`
  # should hold until it is fixed.
  test "the vendor's own project is still gated on framework issues", %{scope: scope} do
    previous = Application.get_env(:code_my_spec, :code_my_spec_project_id)
    Application.put_env(:code_my_spec, :code_my_spec_project_id, scope.active_project.id)
    on_exit(fn -> Application.put_env(:code_my_spec, :code_my_spec_project_id, previous) end)

    accepted(scope, %{scope: :framework, title: "tool_docs ignores requested tool names"})

    assert [issue] = Issues.list_by_status_and_min_severity(scope, :accepted, :medium)
    assert issue.scope == :framework
  end
end
