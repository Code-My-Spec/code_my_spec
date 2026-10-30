defmodule CodeMySpec.Requirements.ADeadProjectorIsNotASettledGraphTest do
  @moduledoc """
  A reader that settles against a projector that dies under the call is not
  told `:ok`. That `:ok` served whatever the rows said as the settled graph, so
  a test killing every project's projector read as an empty graph and spent a
  morning being called a flake (2026-10-14).
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Requirements.IncrementalGraph

  setup do
    scope = full_scope_fixture()
    {:ok, _pid} = IncrementalGraph.ensure_projecting(scope)
    %{scope: scope}
  end

  # The projector is suspended so the reader's call is queued behind it, and
  # only then does the projector go — the call is in flight, not refused.
  defp settle_while(%{scope: scope}, ending) do
    project_id = scope.active_project_id
    # The PID returned during setup may die while its initial seed is draining.
    # Settle that drain, then suspend the projector currently registered for this project.
    :ok = IncrementalGraph.settle(project_id)
    pid = GenServer.whereis(IncrementalGraph.via(project_id))
    :ok = :sys.suspend(pid)
    reader = Task.async(fn -> catch_error(IncrementalGraph.settle(project_id)) end)
    await_queued(pid)
    ending.(pid)
    Task.await(reader)
  end

  defp await_queued(pid), do: pid |> Process.info(:message_queue_len) |> queued(pid)

  defp queued({:message_queue_len, 0}, pid), do: await_queued(pid)
  defp queued(_info, _pid), do: :ok

  test "a projector killed under the call raises with the cause", ctx do
    error = settle_while(ctx, &Process.exit(&1, :kill))

    assert %RuntimeError{message: message} = error
    assert message =~ "did not complete"
    assert message =~ ":killed"
  end
end
