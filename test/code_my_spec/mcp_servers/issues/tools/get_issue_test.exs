defmodule CodeMySpec.McpServers.Issues.Tools.GetIssueTest do
  use ExUnit.Case, async: true
  import CodeMySpec.UsersFixtures
  import CodeMySpec.IssuesFixtures

  alias CodeMySpec.McpServers.Issues.Tools.GetIssue
  alias Anubis.Server.Frame
  alias Anubis.Server.Response

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "execute/2" do
    test "returns issue detail" do
      scope = full_scope_fixture()
      issue = issue_fixture(scope, %{title: "My Bug", severity: :high, description: "It broke"})

      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} = GetIssue.execute(%{issue_id: issue.id}, frame)
      assert response.isError == false

      content = response_text(response)
      assert content =~ "My Bug"
      assert content =~ "high"
      assert content =~ "It broke"
    end

    test "returns error when not found" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      assert {:reply, response, ^frame} =
               GetIssue.execute(%{issue_id: "00000000-0000-0000-0000-000000000000"}, frame)

      assert response.isError == true
    end
  end

  defp response_text(response) do
    protocol = Response.to_protocol(response)
    hd(protocol["content"])["text"]
  end
end
