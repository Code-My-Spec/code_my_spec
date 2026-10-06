defmodule CmsHarness.Agents.Engine.QueueReceipts do
  @moduledoc """
  Message refs and what became of them, surviving a harness restart.

  A queued receipt permits withdrawal and a delivered one refuses it. A ref
  with neither never reached this harness's queue, or the queue holding it was
  dropped before receipts were kept (5150cd98); nothing will deliver it.
  """

  def queued(agent_id, ref), do: write(agent_id, ref, "")

  # Written before execution starts, so a consumed message refuses withdrawal.
  def delivered(agent_id, ref), do: write(agent_id, ref, "delivered")

  @spec withdraw(String.t(), String.t()) :: :ok | {:error, :already_delivered | :never_received}
  def withdraw(agent_id, ref) do
    path = path(agent_id, ref)

    case File.read(path) do
      {:ok, "delivered"} ->
        {:error, :already_delivered}

      {:ok, _queued} ->
        File.rm!(path)

      {:error, :enoent} ->
        {:error, :never_received}

      {:error, reason} ->
        raise File.Error, reason: reason, action: "read queue receipt", path: path
    end
  end

  defp write(agent_id, ref, contents) do
    path = path(agent_id, ref)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp path(agent_id, ref) do
    root =
      Application.get_env(:code_my_spec, :agent_queue_receipts_dir) ||
        Path.join(CmsHarness.Config.local_state_dir(), "agent-queue-receipts")

    Path.join([root, digest(agent_id), digest(ref)])
  end

  defp digest(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)
end
