defmodule CodeMySpec.AgentTasks.IssueFixPromptTest do
  @moduledoc """
  In CodeMySpec's own project a framework issue is this repository's code.

  2026-10-11: a coder tapped out all three issues in its bag as "framework scope,
  not application code in this repo". The prompt had told it "framework defects
  belong to the framework rather than an application workaround" — true in a
  customer's project, and the opposite of true in the vendor's.

  Serial: the vendor is an application env value.
  """

  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.IssuesFixtures
  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.IssueFix

  setup do
    scope = full_scope_fixture()
    issue = issue_fixture(scope, %{status: :accepted, scope: :framework})
    previous = Application.get_env(:code_my_spec, :code_my_spec_project_id)
    on_exit(fn -> restore(previous) end)
    %{scope: scope, issue: issue}
  end

  test "the vendor's coder is told to fix a framework issue here", ctx do
    Application.put_env(:code_my_spec, :code_my_spec_project_id, ctx.scope.active_project.id)

    assert {:ok, prompt} = IssueFix.command(ctx.scope, %{id: "t1", issue_id: ctx.issue.id})
    assert prompt =~ "this repository"
    refute prompt =~ "belong to the framework rather than"
  end

  test "any other project's coder keeps framework defects out of the app", ctx do
    Application.put_env(:code_my_spec, :code_my_spec_project_id, Ecto.UUID.generate())

    assert {:ok, prompt} = IssueFix.command(ctx.scope, %{id: "t1", issue_id: ctx.issue.id})
    assert prompt =~ "belong to the framework rather than"
  end

  defp restore(nil), do: Application.delete_env(:code_my_spec, :code_my_spec_project_id)
  defp restore(value), do: Application.put_env(:code_my_spec, :code_my_spec_project_id, value)
end
