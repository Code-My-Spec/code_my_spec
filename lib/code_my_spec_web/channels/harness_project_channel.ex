defmodule CodeMySpecWeb.HarnessProjectChannel do
  @moduledoc """
  The **data plane** for one project: the channel a light harness holds while
  it owns that project's files.

  Distinct from `HarnessChannel`, which is account-scoped and relays an agent's
  conversation to the operator inbox. This one is project-scoped and carries
  the work — sync results, analysis results, and the lease itself.

  ## The channel is the lease

  Joining takes the project's advisory lock, on a connection this channel
  process owns. Postgres drops that lock when the connection closes, and the
  connection is linked to the channel — so a harness that panics, is killed, or
  simply loses its network frees the project as its socket closes. There is no
  deadline to wait out and no heartbeat to miss.

  That is the reason a channel carries this rather than REST. Not throughput —
  liveness. REST has no "this client is still here" signal, so a lease over
  REST needs an expiry and a heartbeat, which is a timer compensating for a
  deadline.

  A second harness on the same project is refused at join, told who holds it.
  It does not queue: two harnesses syncing one project overwrite each other's
  files and produce a requirement graph matching neither checkout, so the
  second one should stop, not wait.
  """

  use CodeMySpecWeb, :channel

  require Logger

  alias CodeMySpec.Leases
  alias CodeMySpec.Users.Scope

  @impl true
  def join("harness_project:" <> project_id, _payload, socket) do
    scope = socket.assigns[:scope]

    with {:ok, scope} <- authorize(scope, project_id),
         {:ok, holder} <- start_lease_holder(),
         :ok <- claim(scope, holder, socket) do
      {:ok, socket |> assign(:scope, scope) |> assign(:lease_holder, holder)}
    else
      {:error, {:held_by, holder}} ->
        Logger.warning("[HarnessProject] refused #{project_id} — already held by #{holder}")
        {:error, %{reason: "project_in_use", held_by: holder}}

      {:error, reason} ->
        {:error, %{reason: to_string(reason)}}
    end
  end

  def join(_topic, _payload, _socket), do: {:error, %{reason: "invalid topic"}}

  # A harness may only hold a project its credential actually reaches. The
  # socket has already authenticated (user token or project deploy key); this
  # only checks that the project on the topic is the one that scope covers.
  defp authorize(%Scope{active_project_id: pid} = scope, project_id)
       when not is_nil(pid) do
    if to_string(pid) == project_id, do: {:ok, scope}, else: {:error, :unauthorized}
  end

  defp authorize(_scope, _project_id), do: {:error, :unauthorized}

  # Linked, deliberately. This process dying is what releases the lock, so the
  # holder must not outlive the channel — and a holder that cannot start must
  # fail the join rather than silently leave the project unguarded.
  defp start_lease_holder do
    Leases.Session.start_link(name: nil)
  end

  defp claim(scope, holder, socket) do
    Leases.acquire(scope, label_for(socket), holder)
  end

  # Says where the harness is, because the person reading a refusal needs to
  # know which one to go and stop.
  defp label_for(socket) do
    case socket.assigns[:harness_label] do
      label when is_binary(label) and label != "" -> label
      _ -> "a harness on #{inspect(socket.assigns[:peer_data] || "an unknown host")}"
    end
  end
end
