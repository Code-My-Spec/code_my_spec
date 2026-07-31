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

  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Files.Scanner
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

  @doc """
  Hand the harness the small slice of the domain that scanning needs.

  `Files.Scanner` is already the device half of sync: it walks the working
  copy, hashes it, and decides whether each spec is valid, and its own moduledoc
  notes that none of that needs a database and that no file content ever leaves
  it. The one thing it does need is a `ReadModel` — component module names, the
  project's story ids, and whether validation is strict.

  So this is the whole of what a database-less harness requires in order to
  produce a manifest. It is small and it changes slowly, which is why it is
  fetched rather than inferred.
  """
  @impl true
  def handle_in("read_model", _payload, socket) do
    read_model = Scanner.read_model(socket.assigns.scope)

    {:reply, {:ok, serialize_read_model(read_model)}, socket}
  end

  # Take a harness's whole observation set and reconcile it into File rows.
  #
  # The manifest, not a delta. Sending only what changed would be smaller and
  # would make a deletion indistinguishable from an omission — the server would
  # keep rows for files that had gone, and that surfaces much later as a
  # requirement graph citing a spec nobody can find. The full set is what makes
  # the result verifiable.
  #
  # Costs about 150 bytes a file, so a 4,300-file project is roughly 650 KB.
  # Nothing here carries file content: validation already happened on the
  # harness, and only its verdict travels.
  #
  # An empty manifest is refused rather than obeyed. Reconciling one would
  # delete every file row the project has, and over a wire "the scan found
  # nothing" and "the scan did not run" arrive as the same empty list. A
  # genuinely empty project has no rows to lose, so refusing costs nothing and
  # a harness bug stops being indistinguishable from an empty checkout.
  def handle_in("observations", %{"observations" => []}, socket) do
    {:reply, {:error, %{"reason" => "empty_manifest"}}, socket}
  end

  def handle_in("observations", %{"observations" => observations}, socket)
      when is_list(observations) do
    case deserialize_observations(observations) do
      {:ok, entries} ->
        summary = FileSync.reconcile(socket.assigns.scope, entries)

        {:reply,
         {:ok,
          %{
            "upserted" => summary.upserted,
            "removed" => summary.removed,
            "changed" => length(summary.changed_entries)
          }}, socket}

      {:error, problems} ->
        # Usually version skew: a harness classifying files into roles this
        # server has never heard of. Writing those as nil would land wrong rows
        # and surface later as a requirement graph nobody can explain, so the
        # manifest is rejected whole and the reasons are named.
        Logger.warning("[HarnessProject] rejected manifest: #{inspect(problems)}")

        {:reply, {:error, %{"reason" => "invalid_manifest", "problems" => problems}}, socket}
    end
  end

  def handle_in(_event, _payload, socket), do: {:noreply, socket}

  # The whole manifest is validated before any of it is written. A partial
  # apply would leave the project half-described, which is worse than not
  # applying it: the graph would be computed from a mixture of two harnesses'
  # views and match neither.
  defp deserialize_observations(observations) do
    entries = Enum.map(observations, &deserialize_observation/1)

    case Enum.flat_map(entries, &problems/1) |> Enum.uniq() |> Enum.take(20) do
      [] -> {:ok, Enum.map(entries, &Map.delete(&1, :raw_role))}
      problems -> {:error, problems}
    end
  end

  defp problems(%{role: nil, raw_role: raw}), do: ["unknown role: #{inspect(raw)}"]
  defp problems(%{mtime: nil, path: path}), do: ["unparseable mtime on #{path}"]
  defp problems(_entry), do: []

  # Keys are mapped one at a time and roles are matched against the schema's
  # own enum. Nothing here calls String.to_atom on wire data — a harness is
  # authenticated, but "authenticated" is not "allowed to mint atoms in this
  # VM until it runs out of them".
  defp deserialize_observation(observation) do
    %{
      path: observation["path"],
      role: role_atom(observation["role"]),
      raw_role: observation["role"],
      mtime: parse_mtime(observation["mtime"]),
      size: observation["size"],
      fingerprint: observation["fingerprint"],
      valid: observation["valid"],
      validation_errors: observation["validation_errors"],
      component_id: observation["component_id"],
      story_id: observation["story_id"]
    }
  end

  defp role_atom(role) when is_binary(role) do
    Enum.find(Ecto.Enum.values(FileRecord, :role), &(to_string(&1) == role))
  end

  defp role_atom(_), do: nil

  # mtime decides which files are stale, so a nil would crash the comparison in
  # `Files.stale_paths/2` rather than merely lose a timestamp. It is validated,
  # not defaulted.
  defp parse_mtime(%DateTime{} = mtime), do: mtime

  defp parse_mtime(mtime) when is_binary(mtime) do
    case DateTime.from_iso8601(mtime) do
      {:ok, parsed, _offset} -> parsed
      {:error, _} -> nil
    end
  end

  defp parse_mtime(_), do: nil

  # `story_ids` is a MapSet, which has no JSON representation — it crosses as a
  # list and the harness rebuilds it. Everything else is already a plain map.
  defp serialize_read_model(%Scanner.ReadModel{} = read_model) do
    %{
      "component_by_module" => read_model.component_by_module,
      "component_by_id" => read_model.component_by_id,
      "story_ids" => MapSet.to_list(read_model.story_ids),
      "strict" => read_model.strict?
    }
  end

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
