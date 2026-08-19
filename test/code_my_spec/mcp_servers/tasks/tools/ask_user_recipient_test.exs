defmodule CodeMySpec.McpServers.Tasks.Tools.AskUserRecipientTest do
  @moduledoc """
  The reply names whose inbox the question landed in.

  A typed MCP tool is bound to whichever harness its session serves, with no
  parameter to redirect it. So a QA agent exercising the ask→answer round trip
  from a worktree of the real repo asks the *real* owner, reads "Asked", and
  moves on. It happened twice on one story, and story 896 gave questions no
  dismiss and no expiry on purpose — so both are permanent and only that owner
  can clear them (`08d4d7bd`).

  Naming the recipient does not prevent that. Only a way to target another
  harness would, and that is the real fix. This makes the mistake visible in
  the one response the agent is certain to read, at the moment it is made
  rather than when somebody finds the rows weeks later.
  """
  use ExUnit.Case, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.McpServers.Tasks.Tools.AskUser
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    :ok = Sandbox.checkout(CodeMySpec.Repo)
    {:ok, scope: full_scope_fixture()}
  end

  defp frame(scope), do: %Anubis.Server.Frame{assigns: %{current_scope: scope}}

  defp text(response), do: Enum.map_join(response.content, "\n", &Map.get(&1, "text", ""))

  test "the reply names the user and the project", %{scope: scope} do
    {:reply, response, _} = AskUser.execute(%{message: "Which storage backend?"}, frame(scope))

    refute response.isError
    body = text(response)

    assert body =~ scope.user.email,
           "an agent that meant to hit a sandbox needs to see it did not, and the " <>
             "address is the only thing that says so unambiguously"

    assert body =~ scope.active_project.name,
           "two harnesses can serve one owner; the project is what distinguishes " <>
             "the real repo from a QA sandbox belonging to the same person"

    assert body =~ "Question id:",
           "still the thing the agent needs next — check_answer takes it"
  end
end
