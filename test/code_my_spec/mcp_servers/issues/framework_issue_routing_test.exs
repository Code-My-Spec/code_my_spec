defmodule CodeMySpec.McpServers.Issues.FrameworkIssueRoutingTest do
  @moduledoc """
  A framework issue belongs to CodeMySpec, not to the project the agent is in.

  Framework-scoped issues are friction with CodeMySpec itself. The REST path an
  installed CLI files through already knew that:
  `Plugs.ProjectScopeOverride.framework_issue_create?/2` lets any authenticated
  user POST one against the configured CodeMySpec project even without access to
  it, and the CLI sets `x-project-id` accordingly.

  The MCP tool never went through that plug. It resolves the caller's own scope
  and wrote with it, so an agent working in another project filed its framework
  issues into that project — where nobody maintaining the framework will look,
  and where `list_issues` from CodeMySpec cannot see them.

  Measured 2026-08-21: an agent in a `broken_oaths` checkout filed a framework
  issue about the harness and it landed on project `49760b8b-…`. It was found by
  the operator noticing, not by anything in the reply — which is why the reply
  now says where it went.

  Every other scope is deliberately unchanged: `app`, `qa` and `docs` are about
  the project being built, which is the caller's.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.Issues
  alias CodeMySpec.McpServers.Issues.Tools.CreateIssue

  setup do
    # The vendor's project, and an unrelated one an agent is working in. Separate
    # accounts on purpose: the relaxation has to work for a user with no access
    # to CodeMySpec's account, which is every customer.
    vendor_user = user_fixture()
    vendor_account = account_with_owner_fixture(vendor_user)
    vendor_scope = user_scope_fixture(vendor_user, vendor_account)
    code_my_spec = project_fixture(vendor_scope, %{name: "Code My Spec"})

    user = user_fixture()
    account = account_with_owner_fixture(user)
    scope = user_scope_fixture(user, account)
    theirs = project_fixture(scope, %{name: "Broken Oaths"})

    previous = Application.get_env(:code_my_spec, :code_my_spec_project_id)
    Application.put_env(:code_my_spec, :code_my_spec_project_id, code_my_spec.id)
    on_exit(fn -> restore(previous) end)

    %{
      scope: user_scope_fixture(user, account, theirs),
      code_my_spec: code_my_spec,
      theirs: theirs
    }
  end

  defp restore(nil), do: Application.delete_env(:code_my_spec, :code_my_spec_project_id)
  defp restore(value), do: Application.put_env(:code_my_spec, :code_my_spec_project_id, value)

  defp file(scope, params) do
    frame = %Frame{assigns: %{current_scope: scope}}
    {:reply, response, ^frame} = CreateIssue.execute(params, frame)
    {response, Enum.map_join(Response.to_protocol(response)["content"], "\n", & &1["text"])}
  end

  defp issues_in(project_id) do
    Issues.list_issues(%CodeMySpec.Users.Scope{active_project: %{id: project_id}})
  end

  test "a framework issue filed from another project lands on CodeMySpec's", ctx do
    {response, _text} =
      file(ctx.scope, %{
        title: "The stop hook loops",
        description: "Refused every stop for an hour.",
        severity: "high",
        scope: "framework"
      })

    refute response.isError

    assert [%{title: "The stop hook loops", scope: :framework}] = issues_in(ctx.code_my_spec.id)

    assert issues_in(ctx.theirs.id) == [],
           "the project the agent is working in is not where friction with the " <>
             "framework belongs, and it is where nobody maintaining it will look"
  end

  test "and the reply says so, because list_issues here will not show it", ctx do
    {_response, text} =
      file(ctx.scope, %{
        title: "The stop hook loops",
        description: "Refused every stop for an hour.",
        severity: "high",
        scope: "framework"
      })

    assert text =~ ctx.code_my_spec.id

    assert text =~ "not the project you are working in",
           "told only 'Issue created', an agent looks for it with `list_issues`, does " <>
             "not find it, and reads that as the filing having failed"
  end

  # The relaxation the REST plug already makes, made here too: filing friction
  # with the framework must not require access to the framework's account.
  test "the filer needs no access to CodeMySpec's account", ctx do
    refute CodeMySpec.Accounts.user_has_account_access?(
             ctx.scope,
             ctx.code_my_spec.account_id
           )

    {response, _text} =
      file(ctx.scope, %{
        title: "Filed by an outsider",
        description: "…",
        severity: "low",
        scope: "framework"
      })

    refute response.isError
    assert [_] = issues_in(ctx.code_my_spec.id)
  end

  describe "every other scope" do
    for scope <- ~w(app qa docs) do
      test "#{scope} stays with the caller", ctx do
        {response, _text} =
          file(ctx.scope, %{
            title: "About the app being built",
            description: "…",
            severity: "low",
            scope: unquote(scope)
          })

        refute response.isError

        assert [%{title: "About the app being built"}] = issues_in(ctx.theirs.id)
        assert issues_in(ctx.code_my_spec.id) == []
      end
    end
  end

  describe "with no CodeMySpec project configured" do
    setup do
      Application.delete_env(:code_my_spec, :code_my_spec_project_id)
      :ok
    end

    # Filed where the caller is rather than refused. A framework issue in the
    # wrong project is recoverable; losing the report is not.
    test "the issue is still filed, and the log says where it went", ctx do
      log =
        ExUnit.CaptureLog.capture_log(fn ->
          {response, _text} =
            file(ctx.scope, %{
              title: "Nowhere to send it",
              description: "…",
              severity: "low",
              scope: "framework"
            })

          refute response.isError
        end)

      assert [%{scope: :framework}] = issues_in(ctx.theirs.id)
      assert log =~ "no :code_my_spec_project_id is configured"
    end
  end
end
