defmodule CmsHarness.Agents.Engine.QueueReceipts do
  @moduledoc "Unconsumed message refs that survive a harness restart."

  def queued(agent_id, ref) do
    path = path(agent_id, ref)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "")
  end

  # Remove before execution starts. A missing receipt never proves that a
  # message was not consumed; only a surviving receipt permits withdrawal.
  def take(agent_id, ref) do
    case File.rm(path(agent_id, ref)) do
      :ok ->
        true

      {:error, :enoent} ->
        false

      {:error, reason} ->
        raise File.Error,
          reason: reason,
          action: "remove queue receipt",
          path: path(agent_id, ref)
    end
  end

  defp path(agent_id, ref) do
    root =
      Application.get_env(:code_my_spec, :agent_queue_receipts_dir) ||
        Path.join(CmsHarness.Config.local_state_dir(), "agent-queue-receipts")

    Path.join([root, digest(agent_id), digest(ref)])
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
