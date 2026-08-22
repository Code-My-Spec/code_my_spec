defmodule CodeMySpec.McpServers.Issues.FrameworkIssuesTest do
  @moduledoc """
  Framework issues live where they were filed; the vendor reads across.

  Friction with CodeMySpec is reported by agents working in other people's
  projects, so two things have to be true at once: the reporter must be able to
  file, read back and correct its own report, and the people who maintain the
  framework must be able to see all of them.

  For one day it was arranged the other way round — `7c44ed8d` wrote framework
  issues into the configured CodeMySpec project — and the cost was immediate.
  Writing across a tenancy boundary means every read surface needs a matching
  exception, and `get_issue` and `update_issue` did not get one, so an agent
  could file a framework issue and never read it back or correct it. `append`
  exists precisely because reports go stale before their author understands the
  defect, and framework issues were the one kind it could not reach. Three
  agents' Vibium evidence arrived as four separate issues for that reason.

  The exception now sits on the read, where it is one guarded query rather than
  a relaxation smeared across create, get and update — and in the milder
  direction: a vendor reading reports filed *to* the vendor, rather than a
  tenant writing into a project it cannot see.

  The deploy-key intake always worked this way. `FrameworkIssuesController`
  calls `report_framework_issue(project.account_id, project.id, …)` against the
  project its own key names, and it predates the MCP path.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.IssuesFixtures
  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.Issues.Tools.AcceptIssue
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue
  alias CodeMySpec.McpServers.Issues.Tools.DismissIssue
  alias CodeMySpec.McpServers.Issues.Tools.GetIssue
  alias CodeMySpec.McpServers.Issues.Tools.ListIssues
  alias CodeMySpec.McpServers.Issues.Tools.ResolveIssue
  alias CodeMySpec.McpServers.Issues.Tools.UpdateIssue

  setup do
    vendor_user = user_fixture()
    vendor_account = account_with_owner_fixture(vendor_user)
    vendor_base = user_scope_fixture(vendor_user, vendor_account)
    code_my_spec = project_fixture(vendor_base, %{name: "Code My Spec"})

    user = user_fixture()
    account = account_with_owner_fixture(user)
    base = user_scope_fixture(user, account)
    theirs = project_fixture(base, %{name: "Broken Oaths"})

    previous = Application.get_env(:code_my_spec, :code_my_spec_project_id)
    Application.put_env(:code_my_spec, :code_my_spec_project_id, code_my_spec.id)
    on_exit(fn -> restore(previous) end)

    %{
      vendor: user_scope_fixture(vendor_user, vendor_account, code_my_spec),
      caller: user_scope_fixture(user, account, theirs),
      code_my_spec: code_my_spec,
      theirs: theirs
    }
  end

  defp restore(nil), do: Application.delete_env(:code_my_spec, :code_my_spec_project_id)
  defp restore(value), do: Application.put_env(:code_my_spec, :code_my_spec_project_id, value)

  defp run(mod, params, scope) do
    frame = %Frame{assigns: %{current_scope: scope}}
    {:reply, response, ^frame} = mod.execute(params, frame)
    {response, Enum.map_join(Response.to_protocol(response)["content"], "\n", & &1["text"])}
  end

  defp file(scope, title) do
    {response, _} =
      run(
        CreateIssue,
        %{title: title, description: "…", severity: "high", scope: "framework"},
        scope
      )

    refute response.isError
    Enum.find(Issues.list_issues(scope), &(&1.title == title))
  end

  describe "the project that filed it" do
    test "keeps it", ctx do
      issue = file(ctx.caller, "Vibium has no per-caller isolation")

      assert issue.project_id == ctx.theirs.id
      assert issue.scope == :framework
    end

    test "can read it back", ctx do
      issue = file(ctx.caller, "Vibium has no per-caller isolation")

      {response, body} = run(GetIssue, %{issue_id: issue.id}, ctx.caller)

      refute response.isError
      assert body =~ "Vibium has no per-caller isolation"
    end

    # The whole reason this arrangement is better. `append` exists because a
    # report is filed when the evidence is fresh, which is before its author
    # understands the defect — and under the previous arrangement the one kind
    # of issue most likely to need correcting was the one kind that could not be.
    test "can correct it, so a stale report does not become a second report", ctx do
      issue = file(ctx.caller, "Vibium has no per-caller isolation")

      {response, _} =
        run(UpdateIssue, %{issue_id: issue.id, append: "Confirmed by two more agents."}, ctx.caller)

      refute response.isError
      assert Issues.get_issue(ctx.caller, issue.id).description =~ "Confirmed by two more agents."
    end

    test "and sees it in its own framework listing", ctx do
      _issue = file(ctx.caller, "Vibium has no per-caller isolation")

      {response, body} = run(ListIssues, %{scope: "framework"}, ctx.caller)

      refute response.isError
      assert body =~ "Vibium has no per-caller isolation"
    end
  end

  describe "the vendor" do
    test "sees framework issues filed in projects it does not own", ctx do
      _theirs = file(ctx.caller, "Vibium has no per-caller isolation")
      _ours = file(ctx.vendor, "The stop hook loops")

      {response, body} = run(ListIssues, %{scope: "framework"}, ctx.vendor)

      refute response.isError
      assert body =~ "Vibium has no per-caller isolation"
      assert body =~ "The stop hook loops"
    end

    test "does not see another project's app issues", ctx do
      issue_fixture(ctx.caller, %{title: "Their own app bug", scope: :app})

      {_response, body} = run(ListIssues, %{scope: "framework"}, ctx.vendor)

      refute body =~ "Their own app bug"
    end

    # The guard, stated as a property: an ordinary project asking the same
    # question gets its own issues, not everybody's.
    test "is the only one who reads across", ctx do
      _theirs = file(ctx.caller, "Filed by the tenant")
      _ours = file(ctx.vendor, "Filed by the vendor")

      {_response, body} = run(ListIssues, %{scope: "framework"}, ctx.caller)

      assert body =~ "Filed by the tenant"

      refute body =~ "Filed by the vendor",
             "a tenant asking for framework issues gets its own, which is what its " <>
               "author wants to see — the cross-project read is the vendor's alone"
    end

    test "and reading across is refused when no vendor is configured", ctx do
      Application.delete_env(:code_my_spec, :code_my_spec_project_id)

      assert {:error, :not_the_vendor} = Issues.list_framework_issues(ctx.vendor)
    end
  end

  # Seeing a backlog you cannot work is half a feature, and the first cut of
  # this was exactly that: the vendor could list the framework queue and then
  # not dismiss anything in it. Found by trying to close a verification issue
  # and getting "Issue not found".
  #
  # Under the previous arrangement — framework issues written into CodeMySpec's
  # project — leaving triage narrow was right, because the vendor already owned
  # them and the tenant was the outsider. Inverting where they live inverts who
  # the outsider is.
  describe "the vendor works the backlog it can see" do
    setup ctx do
      %{issue: file(ctx.caller, "Filed in another project")}
    end

    test "reads one by id", ctx do
      {response, body} = run(GetIssue, %{issue_id: ctx.issue.id}, ctx.vendor)

      refute response.isError
      assert body =~ "Filed in another project"
    end

    test "accepts one", ctx do
      {response, _} = run(AcceptIssue, %{issue_id: ctx.issue.id}, ctx.vendor)

      refute response.isError
      assert Issues.get_issue(ctx.caller, ctx.issue.id).status == :accepted
    end

    test "dismisses one", ctx do
      {response, _} =
        run(DismissIssue, %{issue_id: ctx.issue.id, reason: "Not a defect."}, ctx.vendor)

      refute response.isError
      assert Issues.get_issue(ctx.caller, ctx.issue.id).status == :dismissed
    end

    test "resolves one", ctx do
      {:reply, _, _} =
        AcceptIssue.execute(%{issue_id: ctx.issue.id}, %Frame{
          assigns: %{current_scope: ctx.vendor}
        })

      {response, _} =
        run(ResolveIssue, %{issue_id: ctx.issue.id, resolution: "Fixed."}, ctx.vendor)

      refute response.isError
      assert Issues.get_issue(ctx.caller, ctx.issue.id).status == :resolved
    end

    # The reporter keeps its own report, which is the point of filing locally.
    test "and the filer can still work its own", ctx do
      {response, _} =
        run(UpdateIssue, %{issue_id: ctx.issue.id, append: "More evidence."}, ctx.caller)

      refute response.isError
      assert Issues.get_issue(ctx.caller, ctx.issue.id).description =~ "More evidence."
    end
  end

  describe "a tenant gains nothing from the vendor's reach" do
    test "cannot touch another project's framework issue", ctx do
      theirs = file(ctx.vendor, "Filed by the vendor")

      {response, _} = run(GetIssue, %{issue_id: theirs.id}, ctx.caller)

      assert response.isError
    end

    # The guard that keeps this from becoming a way to read a stranger's app
    # issues: the vendor's reach is framework-scoped, not project-wide.
    test "and the vendor cannot reach a non-framework issue either", ctx do
      theirs = issue_fixture(ctx.caller, %{title: "Their own app bug", scope: :app})

      {response, _} = run(GetIssue, %{issue_id: theirs.id}, ctx.vendor)

      assert response.isError
    end
  end
end
