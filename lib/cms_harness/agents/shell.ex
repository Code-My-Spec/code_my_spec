defmodule CmsHarness.Agents.Shell do
  @moduledoc """
  Runs an agent's bash command without the harness's own environment.

  Alloy's default bash tool inherits this BEAM's environment, so an agent
  running `mix test` in a project got the harness's `MIX_ENV=harness`, a
  config that project does not have, and every `CMS_*` variable naming this
  harness (the same leak that sent spex harnesses to the real server).
  """

  alias CmsHarness.Agents.Engine.Execution
  alias CmsHarness.Config

  @doc "Runs a command without a deadline, returning its output and exit status."
  @spec run(String.t(), String.t() | nil) :: {String.t(), non_neg_integer()}
  def run(command, dir) do
    opts = [stderr_to_stdout: true, env: Config.scrubbed_env()]
    opts = if dir, do: Keyword.put(opts, :cd, dir), else: opts

    System.cmd("bash", ["-rc", command], opts)
  end

  @doc "Runs with a deadline, retaining output even when the executor times out."
  def run(command, dir, timeout) do
    {:ok, capture} = StringIO.open("")

    try do
      opts = [
        stderr_to_stdout: true,
        env: Config.scrubbed_env(),
        into: IO.binstream(capture, :line)
      ]

      opts = if dir, do: Keyword.put(opts, :cd, dir), else: opts

      task =
        Task.Supervisor.async_nolink(Alloy.TaskSupervisor, fn ->
          System.cmd("bash", ["-rc", command], opts)
        end)

      {result, cleanup} =
        case Task.yield(task, timeout) do
          nil ->
            cleanup = Execution.stop(task.pid)
            Task.shutdown(task, :brutal_kill)
            {nil, cleanup}

          result ->
            {result, nil}
        end

      {_, output} = StringIO.contents(capture)

      case result do
        {:ok, {_, exit_code}} ->
          {:ok, "#{output}\nexit code: #{exit_code}"}

        {:exit, reason} ->
          {:error, "Executor crashed: #{inspect(reason)}\n#{output}"}

        nil ->
          {:error,
           "Command timed out after #{timeout}ms. #{cleanup_status(cleanup)}\nPartial output follows:\n#{output}"}
      end
    after
      StringIO.close(capture)
    end
  end

  defp cleanup_status(:ok), do: "Local command subprocess termination confirmed."

  defp cleanup_status({:error, reason}),
    do: "Local command subprocess termination unconfirmed: #{inspect(reason)}."
end
