defmodule CmsHarness.Attachments do
  @moduledoc "Ephemeral, copy-addressed execution owned by one agent attachment."

  use Boundary,
    top_level?: true,
    deps: [CmsHarness, CmsHarness.Agents, CodeMySpec.ExecutionContexts],
    exports: :all

  alias CmsHarness.Attachments.Session

  def request(root, "attachment_connect", %{"attachment_id" => id}) when is_binary(id) do
    connect(root, id)
  end

  def request(root, "attachment_disconnect", %{"attachment_id" => id}) do
    case lookup(root, id) do
      nil -> :ok
      pid -> GenServer.call(pid, :disconnect, 15_000)
    end
  end

  def request(root, "attachment_execute", %{"attachment_id" => id} = payload) do
    case lookup(root, id) do
      nil -> {:error, :attachment_not_connected}
      pid -> GenServer.call(pid, {:execute, payload}, :infinity)
    end
  catch
    :exit, _ -> {:error, :attachment_unavailable}
  end

  def request(_root, _op, _payload), do: {:error, :invalid_attachment_request}

  defp connect(root, id) do
    case DynamicSupervisor.start_child(CmsHarness.AttachmentsSupervisor, {Session, {root, id}}) do
      {:ok, _pid} -> {:ok, %{attachment_id: id}}
      {:error, {:already_started, _pid}} -> {:ok, %{attachment_id: id}}
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp lookup(root, id) do
    case Registry.lookup(CmsHarness.Registry, {:attachment, root, id}) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end
end
