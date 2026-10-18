defmodule CodeMySpec.Issues.Tools.ListIssuesVisibilityTest do
  use CodeMySpecTest.DataCase, async: true

  alias CodeMySpec.ToolLibrary

  import CodeMySpec.UsersFixtures
  import CodeMySpec.IssuesFixtures
  import Ecto.Query

  alias Anubis.Server.{Frame, Response}
  alias CodeMySpec.Issues
  alias CodeMySpec.Issues.Issue

  test "default and scope union equal the project's open database set at every severity" do
    scope = full_scope_fixture()
    frame = %Frame{assigns: %{current_scope: scope}}

    for issue_scope <- [:app, :qa, :docs, :framework],
        severity <- [:critical, :high, :medium, :low, :info] do
      incoming = issue_fixture(scope, %{scope: issue_scope, severity: severity})
      assert incoming.status == :incoming
      issue = issue_fixture(scope, %{scope: issue_scope, severity: severity})
      assert {:ok, %{status: :accepted}} = Issues.accept_issue(scope, issue)
    end

    closed = issue_fixture(scope)
    {:ok, _} = Issues.dismiss_issue(scope, closed, "closed fixture")
    foreign = issue_fixture(full_scope_fixture(), %{scope: :framework})

    query =
      from(i in Issue,
        where: i.project_id == ^scope.active_project.id and i.status in [:incoming, :accepted]
      )

    database_ids = Repo.all(from(i in query, select: i.id)) |> MapSet.new()
    assert Repo.aggregate(query, :count) == 40
    assert Repo.aggregate(from(i in query, where: i.status == :incoming), :count) == 20

    assert {:ok, result} =
             ToolLibrary.data(
               "list_issues",
               %{},
               Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
             )

    assert ids(result) == database_ids
    assert result["matched"] == 40
    assert result["returned"] == 40
    assert result["project_total"] == 41
    assert result["filtered_out"] == 1
    assert result["filters"]["status"] == "open"
    assert result["filters"]["severity"] == "all"
    refute result["truncated"]
    refute MapSet.member?(ids(result), foreign.id)

    union =
      Enum.reduce(~w(app qa docs framework), MapSet.new(), fn name, acc ->
        assert {:ok, scoped} =
                 ToolLibrary.data(
                   "list_issues",
                   %{scope: name},
                   Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
                 )

        assert scoped["matched"] == 10
        MapSet.union(acc, ids(scoped))
      end)

    assert union == database_ids

    response =
      ToolLibrary.run(
        "list_issues",
        %{},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    text = elem(response, 1)
    assert text =~ "40 matched; 40 returned"
    assert text =~ "1 excluded"
    assert text =~ "status=open"
    for id <- database_ids, do: assert(text =~ id)
    refute text =~ foreign.id
  end

  test "the unchanged default cap is explicit in script and text responses" do
    scope = full_scope_fixture()
    frame = %Frame{assigns: %{current_scope: scope}}
    for _ <- 1..51, do: issue_fixture(scope, %{severity: :low, scope: :framework})

    assert {:ok, result} =
             ToolLibrary.data(
               "list_issues",
               %{},
               Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
             )

    assert result["matched"] == 51
    assert result["returned"] == 50
    assert result["limit"] == 50
    assert result["truncated"]
    assert result["filtered_out"] == 0
    assert length(result["issues"]) == 50

    response =
      ToolLibrary.run(
        "list_issues",
        %{},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    text = elem(response, 1)
    assert text =~ "51 matched; 50 returned"
    assert text =~ "Result capped; 1 more matching issues exist"

    assert {:ok, all} =
             ToolLibrary.data(
               "list_issues",
               %{limit: 51},
               Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
             )

    assert all["returned"] == 51
    refute all["truncated"]
  end

  test "zero matches still disclose exclusions" do
    scope = full_scope_fixture()
    issue_fixture(scope, %{severity: :info})
    frame = %Frame{assigns: %{current_scope: scope}}

    assert {:ok, result} =
             ToolLibrary.data(
               "list_issues",
               %{severity: "high"},
               Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
             )

    assert result["issues"] == []
    assert result["matched"] == 0
    assert result["filtered_out"] == 1

    response =
      ToolLibrary.run(
        "list_issues",
        %{severity: "high"},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    text = elem(response, 1)
    assert text =~ "1 excluded"
    assert text =~ "0 matched; 0 returned"
  end

  test "Lua callers can iterate rows and inspect cap metadata" do
    scope = full_scope_fixture()
    issue_fixture(scope, %{severity: :info})
    issue_fixture(scope, %{severity: :low})
    frame = %Frame{assigns: %{current_scope: scope}}

    script = """
    local result, err = list_issues({limit = 1})
    assert(result ~= nil)
    assert(result.matched == 2)
    assert(result.returned == 1)
    assert(result.truncated == true)
    assert(result.filters.status == 'open')
    assert(result.filters.severity == 'all')
    local count = 0
    for _, row in ipairs(result.issues) do
      assert(row.status == 'incoming')
      count = count + 1
    end
    assert(count == 1)
    return 'listing metadata verified'
    """

    assert {:reply, response, _} =
             CodeMySpec.McpServers.CodeMode.Tools.RunScript.execute(%{script: script}, frame)

    text = hd(Response.to_protocol(response)["content"])["text"]
    refute response.isError, text
    assert text =~ "listing metadata verified"
  end

  defp ids(result), do: MapSet.new(result["issues"], & &1["id"])
end
