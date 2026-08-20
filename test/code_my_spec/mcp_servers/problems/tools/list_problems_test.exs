defmodule CodeMySpec.McpServers.Problems.Tools.ListProblemsTest do
  @moduledoc """
  The tool filters by what it says it filtered by.

  `severity` was declared in the schema, rendered into the header as
  "· severity: error", and never applied to the query. The result was a list of
  every severity wearing a label saying otherwise — worse than ignoring the
  parameter, because the label is the only thing a reader has to go on.

  Both agents who hit it were doing the right thing: checking a stop-hook
  refusal against the record before acting on it (2071faa6, 339725c7). A
  diagnostic tool that answers a different question than the one asked turns
  that check into misinformation, and it is reached exactly when someone has
  already decided something looks wrong.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.AccountsFixtures
  import CodeMySpec.ProblemsFixtures
  import CodeMySpec.ProjectsFixtures
  import CodeMySpec.UsersFixtures

  alias Anubis.Server.Frame
  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Problems.Tools.ListProblems

  setup do
    user = user_fixture()
    account = account_with_owner_fixture(user)
    scope = user_scope_fixture(user, account)
    project = project_fixture(scope)
    scope = user_scope_fixture(user, account, project)

    problem_fixture(scope, %{
      file_path: "lib/broken.ex",
      severity: :error,
      source: "compiler",
      message: "undefined function"
    })

    problem_fixture(scope, %{
      file_path: "lib/style.ex",
      severity: :info,
      source: "credo",
      message: "prefer a pipeline"
    })

    %{scope: scope, frame: %Frame{assigns: %{current_scope: scope}}}
  end

  defp run(params, frame) do
    assert {:reply, response, ^frame} = ListProblems.execute(params, frame)
    {response, hd(Response.to_protocol(response)["content"])["text"]}
  end

  describe "severity" do
    test "narrows the list to that severity", ctx do
      {response, text} = run(%{severity: "error"}, ctx.frame)

      assert response.isError == false
      assert text =~ "lib/broken.ex"

      refute text =~ "lib/style.ex",
             "the header says `severity: error`; an info finding under that label is " <>
               "the tool contradicting itself"
    end

    test "narrows the count as well as the page", ctx do
      {_response, text} = run(%{severity: "error"}, ctx.frame)

      assert text =~ "(1 of 1)",
             "a total counting findings the filter excludes describes a different " <>
               "question than the one asked"
    end

    test "omitting it returns every severity", ctx do
      {_response, text} = run(%{}, ctx.frame)

      assert text =~ "lib/broken.ex"
      assert text =~ "lib/style.ex"
    end

    test "an unrecognised value is refused, not ignored", ctx do
      {response, _text} = run(%{severity: "critical"}, ctx.frame)

      assert response.isError,
             "a filter that quietly does nothing cannot be told apart from one that " <>
               "matched nothing, which is the whole defect"
    end
  end

  describe "an empty result" do
    test "names the filters that produced it", ctx do
      {_response, text} = run(%{severity: "warning"}, ctx.frame)

      assert text =~ "severity warning",
             "'No problems recorded for this working copy' under a filter reads as " <>
               "'this working copy is clean', and an agent checking a refusal against " <>
               "the record will conclude the refusal is phantom"
    end

    test "says how to widen it", ctx do
      {_response, text} = run(%{severity: "warning"}, ctx.frame)

      assert text =~ "Call without them for all."
    end
  end
end
