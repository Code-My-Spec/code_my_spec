defmodule CodeMySpecTest.DataCase do
  @moduledoc """
  The test case setup for tests requiring access to the application's data
  layer.

  You may define functions here to be used as helpers in
  your tests.

  Finally, if the test case interacts with the database,
  we enable the SQL sandbox, so changes done to the database
  are reverted at the end of every test. If you are using
  PostgreSQL, you can even run database tests asynchronously
  by setting `use CodeMySpec.DataCase, async: true`, although
  this option is not recommended for other databases.
  """

  use ExUnit.CaseTemplate

  alias Ecto.Adapters.SQL

  using do
    quote do
      alias CodeMySpec.Repo

      import Ecto
      import Ecto.Changeset
      import Ecto.Query
      import CodeMySpecTest.DataCase
    end
  end

  setup tags do
    CodeMySpecTest.DataCase.setup_sandbox(tags)
    :ok
  end

  @doc """
  Sets up the sandbox based on the test tags.
  """
  def setup_sandbox(tags) do
    pid = SQL.Sandbox.start_owner!(CodeMySpec.Repo, shared: not tags[:async])
    on_exit(fn -> SQL.Sandbox.stop_owner(pid) end)

    # 2aa4c832: a fire-and-forget Task started under CodeMySpec.TaskSupervisor
    # (Agents.dispatch_admitted's async branch, among others) can still be
    # running after this test's own process exits, and then tries to use the
    # connection `stop_owner/1` just checked back in. Registered after the
    # line above: ExUnit runs on_exit callbacks LIFO, so this drain runs
    # before the checkin, not after it.
    before = CodeMySpec.TaskSupervisor |> Task.Supervisor.children() |> MapSet.new()
    on_exit(fn -> await_background_work(before) end)
  end

  @doc """
  Block until every Task started under `CodeMySpec.TaskSupervisor` since
  `before` (a snapshot from `Task.Supervisor.children/1`) has finished, or
  half a second has passed.

  Shared with `CodeMySpecTest.AgentTransportRouter`, which drains the same
  supervisor for the same reason on a narrower trigger (routing a project);
  this runs unconditionally for every sandboxed test.
  """
  @spec await_background_work(MapSet.t(), integer()) :: :ok
  def await_background_work(before, deadline \\ System.monotonic_time(:millisecond) + 500) do
    still_running =
      CodeMySpec.TaskSupervisor
      |> Task.Supervisor.children()
      |> MapSet.new()
      |> MapSet.difference(before)

    cond do
      Enum.empty?(still_running) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        :ok

      true ->
        Process.sleep(10)
        await_background_work(before, deadline)
    end
  end

  @doc """
  A helper that transforms changeset errors into a map of messages.

      assert {:error, changeset} = Accounts.create_user(%{password: "short"})
      assert "password is too short" in errors_on(changeset).password
      assert %{password: ["password is too short"]} = errors_on(changeset)

  """
  def errors_on(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
