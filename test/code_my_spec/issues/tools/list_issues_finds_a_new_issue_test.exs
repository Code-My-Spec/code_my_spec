defmodule CodeMySpec.Issues.Tools.ListIssuesFindsANewIssueTest do
  @moduledoc """
  6da8e0e5: `list_issues({})` returned all 547 of metric_flow's issues by
  severity and the reply was cut at 24KB, so a medium issue filed a minute
  earlier was never in it.
  """
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.IssuesFixtures
  import CodeMySpec.UsersFixtures
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias CodeMySpec.Issues

  defp file(scope, title, attrs \\ %{}),
    do: issue_fixture(scope, Map.merge(%{title: title, severity: :high}, attrs))

  defp listed(scope, params) do
    response =
      ToolLibrary.run("list_issues", params, %{scope: scope})

    response_text(response)
  end

  setup do
    %{scope: full_scope_fixture()}
  end

  test "the newest open issue is listed first, past a page of older ones", %{scope: scope} do
    for n <- 1..5, do: file(scope, "old high issue #{n}")
    file(scope, "the help page is missing", %{severity: :medium})

    text = listed(scope, %{limit: 3})

    assert [first | _] = Regex.scan(~r/^- .*$/m, text) |> List.flatten()
    assert first =~ "the help page is missing"
    assert text =~ "Showing the newest 3 of 6"
  end

  test "closed issues are left out unless asked for", %{scope: scope} do
    issue = file(scope, "already dealt with")
    {:ok, _} = Issues.dismiss_issue(scope, issue, "not a bug")

    refute listed(scope, %{}) =~ "already dealt with"
    assert listed(scope, %{status: "all"}) =~ "already dealt with"
  end

  test "all severities are included unless explicitly filtered", %{scope: scope} do
    file(scope, "a medium one", %{severity: :medium})
    file(scope, "a low one", %{severity: :low})
    file(scope, "an info one", %{severity: :info})

    text = listed(scope, %{})
    assert text =~ "a medium one"
    assert text =~ "a low one"
    assert text =~ "an info one"
    assert text =~ "3 matched; 3 returned"
    refute listed(scope, %{severity: "low"}) =~ "an info one"

    assert listed(scope, %{severity: "all"}) =~ "an info one"
    assert listed(scope, %{severity: "low"}) =~ "a low one"
  end

  test "each issue is one line, without its description", %{scope: scope} do
    file(scope, "a title\nover two lines", %{description: "the long account of it"})

    text = listed(scope, %{})

    assert text =~ "- [high] a title over two lines (incoming) — ID: "
    refute text =~ "the long account of it"
  end

  test "query finds an issue by its words", %{scope: scope} do
    file(scope, "the help page is missing")
    file(scope, "something else")

    text = listed(scope, %{query: "HELP page"})

    assert text =~ "the help page is missing"
    refute text =~ "something else"
  end
end
