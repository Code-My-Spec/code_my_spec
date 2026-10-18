defmodule CodeMySpecSpex.OfferHelpers do
  @moduledoc """
  Reading offers the way main does: through `list_offers` (b75b0198).

  The spex for story 1080 drive real nudge paths and observe the result here,
  never in the table. Parsing the tool's text is deliberate: what these
  criteria claim is what main can read.
  """

  import CodeMySpecSpex.IdleAgentHelpers,
    only: [put_to_work: 1, start_session: 1, start_agent_task: 3]

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]
  import ExUnit.Assertions

  alias CodeMySpec.ToolLibrary
  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.FullSatisfactionFixtures
  alias CodeMySpecSpex.HarnessHooks

  @doc "`list_offers`' text for this project, with optional filters."
  @spec listing(map(), map()) :: String.t()
  def listing(context, filters \\ %{}) do
    frame = %Frame{assigns: %{current_scope: context.scope}}

    response =
      ToolLibrary.run(
        "list_offers",
        filters,
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    case response do
      {:ok, text} -> text
      {:error, text} -> raise("list_offers refused: " <> text)
    end
  end

  @doc """
  This agent's offers, newest first, each as a map of what `list_offers` shows:
  `:kind`, `:subject`, `:attempt`, `:status`, `:messages` (the excerpts) and
  `:reason`/`:note` when set.
  """
  @spec offers(map(), String.t(), map()) :: [map()]
  def offers(context, agent_id, filters \\ %{}) do
    context
    |> listing(Map.put(filters, :agent_id, agent_id))
    |> parse()
  end

  @doc "The offers in a `list_offers` text."
  @spec parse(String.t()) :: [map()]
  def parse(text) do
    text
    |> String.split(~r/^offer /m)
    |> Enum.drop(1)
    |> Enum.map(&block/1)
  end

  defp block(text) do
    [_, kind, subject, attempt] = Regex.run(~r/^  (\w+) on (\S+), attempt (\d+)$/m, text)
    [_, status] = Regex.run(~r/^  status: (\w+)/m, text)

    %{
      kind: kind,
      subject: subject,
      attempt: String.to_integer(attempt),
      status: status,
      reason: field(text, "reason"),
      note: field(text, "note"),
      messages:
        ~r/^    - \S+ at \S+: (.*)$/m
        |> Regex.scan(text, capture: :all_but_first)
        |> List.flatten()
    }
  end

  defp field(text, name) do
    case Regex.run(~r/^  #{name}: (.*)$/m, text) do
      [_, value] -> value
      nil -> nil
    end
  end

  @doc "A message as `list_offers` excerpts it: whitespace collapsed, cut at 300."
  @spec excerpt(String.t()) :: String.t()
  def excerpt(text) do
    flat = text |> String.replace(~r/\s+/, " ") |> String.trim()
    if String.length(flat) > 300, do: String.slice(flat, 0, 300) <> "…", else: flat
  end

  @doc "The frame an agent's own tool calls are made in."
  @spec agent_frame(map(), String.t()) :: Frame.t()
  def agent_frame(context, agent_id),
    do: %Frame{assigns: %{current_scope: context.scope, agent_id: agent_id}}

  @doc "The `start_task` arguments `get_next_requirement` names for this agent."
  @spec next_task(map(), String.t()) :: map()
  def next_task(context, agent_id) do
    frame = agent_frame(context, agent_id)

    response =
      ToolLibrary.run(
        "get_next_requirement",
        %{},
        Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
      )

    [_, name, type, id] =
      Regex.run(
        ~r/requirement_name=`(\w+)`, entity_type=`(\w+)`, entity_id=`([^`]+)`/,
        response_text(response)
      )

    %{requirement_name: name, entity_type: type, entity_id: id}
  end

  @doc "Read off `list_tasks` rather than the row: the id the agent itself is shown."
  @spec held_task_id(map(), String.t()) :: String.t()
  def held_task_id(context, agent_id) do
    tasks =
      ToolLibrary.run(
        "list_tasks",
        %{},
        Map.put(
          agent_frame(context, agent_id).assigns,
          :scope,
          agent_frame(context, agent_id).assigns[:current_scope]
        )
      )

    [_, task_id] = Regex.run(~r/([0-9a-f]{8}-[0-9a-f-]{27})/, response_text(tasks))
    task_id
  end

  @doc """
  What the harness sends when an agent's turn fails, on the channel it sends
  it on.
  """
  @spec report_turn_failed(map(), String.t(), String.t()) :: :ok
  def report_turn_failed(context, agent_id, text) do
    socket = %Phoenix.Socket{assigns: %{scope: context.scope}}

    case CodeMySpecWeb.HarnessProjectChannel.handle_in(
           "agent_turn_event",
           %{"agent_id" => agent_id, "event" => %{"kind" => "turn_failed", "text" => text}},
           socket
         ) do
      {:noreply, _} -> :ok
      {:reply, _, _} -> :ok
    end

    Fixtures.end_turn(context.scope, agent_id)
  end

  @doc """
  What a harness that has just come back reports about the agents it is
  running, on the channel it reports it on — a fresh connection, so the cloud's
  once-per-connection sweep runs.
  """
  @spec report_agents_present(map(), [String.t()]) :: :ok
  def report_agents_present(context, agent_ids) do
    socket = %Phoenix.Socket{assigns: %{scope: context.scope}}

    {:reply, :ok, _socket} =
      CodeMySpecWeb.HarnessProjectChannel.handle_in(
        "agents_present",
        %{"agent_ids" => agent_ids},
        socket
      )

    :ok
  end

  @doc """
  Coding work waiting on a switched-on copy: everything but the spex run, the
  premise criterion 1184 settled on.

  Served by a live harness before the runs are recorded: a run's freshness
  belongs to a working copy, and the copy the agent's session, task and menu
  are on is the harness's. Recorded on the fixture copy, the agent's own copy
  reads stale analysis and its task is never ready to resume. A feature
  checkout, because a coder holds a story only off the main copy.
  """
  @spec coding_work_waiting(map()) :: map()
  def coding_work_waiting(context) do
    context =
      context
      |> FullSatisfactionFixtures.apply_up_to_analysis()
      |> HarnessHooks.ensure_live_harness(feature: true)

    Fixtures.fresh_analysis_runs(context.scope, ["compiler", "credo", "exunit"])
    context
  end

  @doc """
  A continuous coder offered that work by switching its copy on, its turn
  under way. Needs the recording transport installed.
  """
  @spec offered_work(map()) :: map()
  def offered_work(context) do
    context = coding_work_waiting(context)
    coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
    context = context |> start_session() |> put_to_work()
    id = coder.id
    assert_receive {:work_turn_requested, ^id, _ref, _prompt}, 2_000
    :ok = Fixtures.put_agent_mid_turn(context.scope, id)
    Map.put(context, :coder, id)
  end

  @doc """
  A continuous coder that claimed the work through `start_task`, with no turn
  in flight. Answers `:coder`, `:task` (the start_task arguments) and
  `:task_id`.
  """
  @spec coder_holding_a_task(map()) :: map()
  def coder_holding_a_task(context) do
    context = context |> coding_work_waiting() |> start_session() |> put_to_work()
    coder = Fixtures.running_agent(context.scope, role: "coding", continuous: true)
    task = next_task(context, coder.id)
    context = start_agent_task(context, coder.id, task)

    Map.merge(context, %{coder: coder.id, task: task, task_id: held_task_id(context, coder.id)})
  end

  @doc """
  A coder holding a task that ended a turn, was handed the menu, and has
  started its next turn. Needs the recording transport installed.
  """
  @spec handed_the_menu(map()) :: map()
  def handed_the_menu(context) do
    context = coder_holding_a_task(context)
    id = context.coder
    :ok = Fixtures.put_agent_mid_turn(context.scope, id)
    :ok = Fixtures.end_turn(context.scope, id)
    assert_receive {:agent_dispatch, ^id, _ref, "Your turn is done" <> _}, 2_000
    :ok = Fixtures.put_agent_mid_turn(context.scope, id)
    context
  end
end
