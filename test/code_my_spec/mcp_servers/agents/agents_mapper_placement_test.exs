defmodule CodeMySpec.McpServers.Agents.AgentsMapperPlacementTest do
  @moduledoc """
  Where an agent runs and where it is recorded are two different facts, and the
  reply used to print only the first.

  `Agents.id_for/2` falls back to the caller's own copy when a named root
  resolves to no row for this device and project. That is deliberate — a
  checkout that has never joined should not be a refusal — but it was silent,
  and `started/1` printed the root that had been *asked for*. QA of story 988
  named `.../qa_sandbox`, was answered "Working copy: .../qa_sandbox", and got a
  row pointing at the main checkout. Issue `af85efc7`.

  It matters because the stop decision and the analyzer alert are both computed
  from the recorded copy: an agent editing one tree would be told about another,
  with nothing saying so.

  Nothing is moved to fix it. Rewriting the root would relocate the agent into
  whichever checkout the caller happened to be in — for the QA case, the
  framework's own — which is worse than the bug. The disagreement is announced
  instead.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Agents.Agent
  alias CodeMySpec.McpServers.Agents.AgentsMapper
  alias CodeMySpec.Utils.MapAccess
  alias CodeMySpec.WorkingCopies

  defp text(response) do
    response
    |> Map.get(:content, [])
    |> Enum.map_join("\n", &MapAccess.get(&1, :text, ""))
  end

  defp agent_on(scope, root) do
    %Agent{
      id: Ecto.UUID.generate(),
      engine: :alloy,
      provider: "openai-codex",
      role: "coding",
      status: :running,
      working_copy: root,
      working_copy_id: scope.active_working_copy_id,
      project_id: scope.active_project_id,
      account_id: scope.active_account_id
    }
  end

  test "a root that matches the recorded copy says nothing extra" do
    scope = full_scope_fixture()
    {:ok, copy} = WorkingCopies.fetch(scope.active_working_copy_id)

    rendered = scope |> agent_on(copy.root) |> AgentsMapper.started() |> text()

    assert rendered =~ "Working copy: #{copy.root}"

    refute rendered =~ "Recorded against",
           "the agent runs where it is recorded, so there is nothing to warn about:\n#{rendered}"
  end

  test "a root that does not match the recorded copy is called out" do
    scope = full_scope_fixture()
    {:ok, copy} = WorkingCopies.fetch(scope.active_working_copy_id)

    elsewhere = "/tmp/some-other-checkout"
    refute elsewhere == copy.root, "the two roots must differ or this asserts nothing"

    rendered = scope |> agent_on(elsewhere) |> AgentsMapper.started() |> text()

    assert rendered =~ "Working copy: #{elsewhere}",
           "the agent runs where it was told, and the reply must still say so"

    assert rendered =~ "Recorded against: #{copy.root}", """
    The reply named the root that was asked for and not the copy the row points
    at. Analysis and the stop decision are computed from the recorded copy, so a
    caller reading only the first line is told an agent is somewhere it is not
    being judged.

    #{rendered}
    """
  end
end
