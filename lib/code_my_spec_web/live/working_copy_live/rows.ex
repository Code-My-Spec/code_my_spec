defmodule CodeMySpecWeb.WorkingCopyLive.Rows do
  @moduledoc """
  The one reading of "what is this working copy": the copy, the agents on it,
  and each agent's conversation. Used by the working copy Index, Show and
  Status pages and the agent conversation's team panel, so they cannot
  disagree.

  A working copy is one checkout (`WorkingCopies.issue/3` mints its id). It runs
  one or more agents, each with its own conversation, so `chats` has one entry
  per agent that has one.

  Read-only: conversations are looked up, never created. This runs on mount
  and on every broadcast.

  `label` is the stored name or the whole root (a list row can truncate it).
  `heading` is `WorkingCopies.display_name/1`, the shortest identifying string,
  for page titles.
  """

  alias CodeMySpec.Agents
  alias CodeMySpec.AppInstances
  alias CodeMySpec.Analysis.HarnessRegistry
  alias CodeMySpec.Conversations
  alias CodeMySpec.Devices.Device
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecWeb.WorkingCopyLive.Liveness

  @type row :: %{
          harness: struct(),
          label: String.t(),
          agents: [struct()],
          chats: [%{agent: struct(), conversation: struct(), message_count: non_neg_integer()}],
          heading: String.t(),
          device: struct() | nil,
          device_name: String.t() | nil,
          message_count: non_neg_integer(),
          last_message_at: DateTime.t() | nil,
          liveness: Liveness.summary(),
          missing: %{since: String.t() | nil} | nil,
          last_message: String.t() | nil,
          other_copies_at_root: non_neg_integer() | nil
        }

  @doc """
  Every working copy on the project, newest first.

  Agents come from `Agents.list_on_duty/1`. `opts[:include_stopped?]` (default
  `false`) uses `Agents.list_for_team_status/1` instead, so a role's slot keeps
  its most recently stopped agent. Only the agent conversation's team panel
  opts in; `WorkingCopyLive.Show` relies on stopped agents being absent ("Staff
  it", no chat box for a stopped agent).
  """
  @spec list(map(), struct(), DateTime.t(), keyword()) :: [row()]
  def list(scope, project, now, opts \\ []) do
    agents =
      if Keyword.get(opts, :include_stopped?, false) do
        Agents.list_for_team_status(scope)
      else
        Agents.list_on_duty(scope)
      end
      |> Agents.with_lifecycle(Agents.present_ids(scope))

    transcripts = transcripts(scope, project)

    scope
    |> WorkingCopies.list_harnesses()
    |> Enum.map(&build(scope, &1, agents, transcripts, now))
    |> Enum.sort_by(&(not &1.harness.main))
    |> group_by_root()
  end

  # Groups rows for the same checkout seen under several ids (a device
  # re-announcing under a new id), keyed on root and device name. Nothing is
  # hidden: every row stays, individually offboardable. First-occurrence order
  # keeps the recency sort.
  # See knowledge/web, "Working copy rows".
  defp group_by_root(rows) do
    order = rows |> Enum.map(&group_key/1) |> Enum.uniq()
    groups = Enum.group_by(rows, &group_key/1)

    Enum.flat_map(order, fn key -> tag_group(Map.fetch!(groups, key)) end)
  end

  defp group_key(row), do: {row.harness.root, row.device_name}

  defp tag_group([only]), do: [Map.put(only, :other_copies_at_root, nil)]

  defp tag_group([first | rest]) do
    [
      Map.put(first, :other_copies_at_root, length(rest))
      | Enum.map(rest, &Map.put(&1, :other_copies_at_root, nil))
    ]
  end

  @doc """
  One working copy by its harness id, or nil.

  Found inside the project's own list rather than by a bare id lookup: the id
  arrives on a URL, and `WorkingCopies.fetch/1` answers for any harness on any
  project.
  """
  @spec get(map(), struct(), String.t(), DateTime.t(), keyword()) :: row() | nil
  def get(scope, project, working_copy_id, now, opts \\ []) do
    scope
    |> list(project, now, opts)
    |> Enum.find(&(&1.harness.id == working_copy_id))
  end

  # Keyed by agent: a conversation belongs to an agent.
  defp transcripts(scope, project) do
    scope
    |> Conversations.list_agent_conversations(project.id)
    |> Map.new(&{&1.conversation.agent_id, &1})
  end

  defp build(scope, harness, agents, transcripts, now) do
    heading = WorkingCopies.display_name(harness)
    missing = missing(harness, now)
    instance = default_instance(scope, harness)

    harness =
      harness
      |> Map.from_struct()
      |> Map.merge(%{
        app_instance_id: instance && instance.id,
        app_status: instance && instance.status,
        app_url: instance && instance.url,
        app_commit: instance && instance.serving_commit,
        preview_status: instance && instance.preview_status,
        preview_url: instance && instance.preview_url
      })

    on_this_copy =
      agents |> Enum.filter(&(&1.working_copy_id == harness.id)) |> Enum.sort_by(& &1.role)

    chats = Enum.flat_map(on_this_copy, &chat(&1, transcripts))
    latest = latest_message_at(chats)

    %{
      harness: harness,
      device: device(harness),
      device_name: device_name(harness),
      label: harness.label || harness.root,
      heading: heading,
      agents: on_this_copy,
      chats: chats,
      # The copy's totals, summed across its agents.
      message_count: Enum.sum(Enum.map(chats, & &1.message_count)),
      last_message_at: latest,
      last_message: latest && Liveness.since(latest, now),
      liveness: Liveness.working_copy(on_this_copy, now),
      # Whether a harness holds this checkout, from the registry (live by
      # construction). Distinct from liveness, which is what agents last said.
      served: match?({:ok, _pid, _instance}, HarnessRegistry.executor_holder(harness.id)),
      missing: missing
    }
  end

  defp default_instance(scope, %{default_app_instance: %Ecto.Association.NotLoaded{}} = copy),
    do: AppInstances.for_working_copy(scope, copy)

  defp default_instance(_scope, %{default_app_instance: instance}), do: instance

  defp default_instance(scope, copy), do: AppInstances.for_working_copy(scope, copy)

  # An agent with no conversation yet contributes nothing; never create one here.
  defp chat(agent, transcripts) do
    case Map.get(transcripts, agent.id) do
      nil ->
        []

      transcript ->
        [
          %{
            agent: agent,
            conversation: transcript.conversation,
            message_count: transcript.message_count,
            last_message_at: transcript.last_message_at
          }
        ]
    end
  end

  defp latest_message_at([]), do: nil

  defp latest_message_at(chats) do
    chats
    |> Enum.map(& &1.last_message_at)
    |> Enum.reject(&is_nil/1)
    |> Enum.max(DateTime, fn -> nil end)
  end

  # Whether the checkout is gone from its root, as its machine last reported.
  # Separate from `liveness`: an agent can outlive its directory. nil covers both
  # "present" and "never checked"; neither warrants a warning.
  defp missing(%{path_missing_since: nil}, _now), do: nil
  defp missing(%{path_missing_since: at}, now), do: %{since: Liveness.since(at, now)}

  # The machine this copy is on, or nil (never reported, or the device was
  # destroyed; indistinguishable here).
  defp device(%{device: %Device{} = device}), do: device
  defp device(_working_copy), do: nil

  defp device_name(working_copy) do
    case device(working_copy) do
      nil -> nil
      device -> Device.display_name(device)
    end
  end
end
