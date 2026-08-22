defmodule CodeMySpec.McpServers.Issues.FrameworkIssueMaintenanceTest do
  @moduledoc """
  An agent can read back and correct the framework issue it filed.

  Filing a framework issue writes it against the configured CodeMySpec project
  rather than the caller's (7c44ed8d), because friction with the framework
  belongs to the framework. Reading stayed scoped to the caller's own project,
  so the two halves disagreed: an agent could file one and then never see it
  again, append to it, or correct it.

  `append` exists precisely because reports go stale — "an agent files an issue
  at the moment it has the evidence, which is often before it understands the
  defect". That is exactly the kind of issue this closed off, and the workaround
  is another issue.

  Measured 2026-08-21: four separate reports of one Vibium defect, the fullest
  of them opening "could not append to that issue directly — cross-project
  scoping, same limitation as before — so filing this as the authoritative,
  fuller version instead". Three agents' evidence across four issues, because
  the surface that would have consolidated them was closed.

  The widening is deliberately narrow, and these pin both edges: framework
  issues only, and reading and correcting only. What happens to a framework
  report — accepted, dismissed, resolved — stays with the people who maintain
  the framework, so the triage tools do not pass the flag.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.IssuesFixtures
  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.Issues.Tools.GetIssue
  alias CodeMySpec.McpServers.Issues.Tools.UpdateIssue

  setup do
    vendor_user = user_fixture()
    vendor_account = account_with_owner_fixture(vendor_user)
    vendor_scope = user_scope_fixture(vendor_user, vendor_account)
    code_my_spec = project_fixture(vendor_scope, %{name: "Code My Spec"})
    vendor_scope = user_scope_fixture(vendor_user, vendor_account, code_my_spec)

    user = user_fixture()
    account = account_with_owner_fixture(user)
    scope = user_scope_fixture(user, account)
    theirs = project_fixture(scope, %{name: "Broken Oaths"})

    previous = Application.get_env(:code_my_spec, :code_my_spec_project_id)
    Application.put_env(:code_my_spec, :code_my_spec_project_id, code_my_spec.id)
    on_exit(fn -> restore(previous) end)

    %{
      caller: user_scope_fixture(user, account, theirs),
      vendor_scope: vendor_scope,
      code_my_spec: code_my_spec
    }
  end

  defp restore(nil), do: Application.delete_env(:code_my_spec, :code_my_spec_project_id)
  defp restore(value), do: Application.put_env(:code_my_spec, :code_my_spec_project_id, value)

  defp text(response), do: Enum.map_join(response.content, "\n", &Map.get(&1, "text", ""))

  defp frame(scope), do: %Frame{assigns: %{current_scope: scope}}

  defp run(mod, params, scope) do
    {:reply, response, _frame} = mod.execute(params, frame(scope))
    {response, Enum.map_join(Response.to_protocol(response)["content"], "\n", & &1["text"])}
  end

  describe "an issue filed against the framework" do
    setup ctx do
      issue =
        issue_fixture(ctx.vendor_scope, %{
          title: "Vibium has no per-caller isolation",
          scope: :framework
        })

      %{issue: issue}
    end

    test "can be read back by the agent that filed it", ctx do
      {response, body} = run(GetIssue, %{issue_id: ctx.issue.id}, ctx.caller)

      refute response.isError
      assert body =~ "Vibium has no per-caller isolation"
    end

    test "can be corrected, which is why filing early is safe", ctx do
      {response, _body} =
        run(
          UpdateIssue,
          %{issue_id: ctx.issue.id, append: "Confirmed by two more agents."},
          ctx.caller
        )

      refute response.isError

      reloaded = Issues.get_issue(ctx.vendor_scope, ctx.issue.id)
      assert reloaded.description =~ "Confirmed by two more agents."
    end

    # The 8-character form every commit message and issue body in this codebase
    # uses. Reading back by prefix has to cross the same boundary, or the
    # id an agent actually has in hand is the one that does not work.
    test "can be read back by the prefix the agent was given", ctx do
      prefix = String.slice(ctx.issue.id, 0, 8)

      {response, body} = run(GetIssue, %{issue_id: prefix}, ctx.caller)

      refute response.isError
      assert body =~ "Vibium has no per-caller isolation"
    end
  end

  describe "the widening stops where it should" do
    # Someone else's app issue in the framework project is that project's own
    # business. Only `scope: framework` crosses.
    test "an app-scoped issue in the framework project stays private", ctx do
      theirs = issue_fixture(ctx.vendor_scope, %{title: "Internal app bug", scope: :app})

      {response, _body} = run(GetIssue, %{issue_id: theirs.id}, ctx.caller)

      assert response.isError
    end

    # Triage is not widened: deciding what happens to a framework report stays
    # with the people who maintain the framework.
    test "the triage lookup does not reach across", ctx do
      issue = issue_fixture(ctx.vendor_scope, %{title: "Framework friction", scope: :framework})

      assert Issues.get_issue(ctx.caller, issue.id) == nil,
             "the default lookup is unchanged; only callers that ask for " <>
               "include_framework cross the boundary"
    end
  end
end
