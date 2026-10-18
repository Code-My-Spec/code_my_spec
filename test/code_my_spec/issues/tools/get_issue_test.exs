defmodule CodeMySpec.Issues.Tools.GetIssueTest do
  use ExUnit.Case, async: true

  alias CodeMySpec.ToolLibrary
  import CodeMySpec.UsersFixtures
  import CodeMySpec.IssuesFixtures

  alias Anubis.Server.Frame
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
  end

  describe "execute/2" do
    test "returns issue detail" do
      scope = full_scope_fixture()
      issue = issue_fixture(scope, %{title: "My Bug", severity: :high, description: "It broke"})

      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "get_issue",
          %{issue_id: issue.id},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:ok, _}, response)

      content = response_text(response)
      assert content =~ "My Bug"
      assert content =~ "high"
      assert content =~ "It broke"
    end

    test "returns error when not found" do
      scope = full_scope_fixture()
      frame = %Frame{assigns: %{current_scope: scope}}

      response =
        ToolLibrary.run(
          "get_issue",
          %{issue_id: "00000000-0000-0000-0000-000000000000"},
          Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
        )

      assert match?({:error, _}, response)
    end
  end

  defp response_text({_status, text}), do: text
end
