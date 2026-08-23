defmodule CodeMySpecWeb.WorkingCopiesLive do
  @moduledoc """
  Every working copy on a project, and what is running on each.

  A harness is a working copy. `Harnesses.issue/3` mints one id per checkout on
  join, so "harness id" and "working copy id" are the same thing — said here in
  the user's words rather than left for them to infer. The list is the set of
  copies, not the set of agents: a checkout running nothing is a row, because a
  copy that is absent reads as a copy that does not exist.

  ## Liveness is two facts, and they are not interchangeable

  A Pi lane is tracked in Presence on the harness channel — joined for exactly as
  long as its process lives. Its liveness is a fact about now, so it says
  **Present**.

  A Claude Code agent has no channel to be present on. It reports over HTTP
  hooks: `SessionStart` writes a row and `touch_session/2` bumps a timestamp. What
  is known is when it last did something, so it says **Last heard from**. An
  agent that died five minutes ago and one mid-thought produce the same
  timestamp, and calling that presence would invent the difference.

  ## What this page does not do

  It does not start or stop anything, and that is a decision rather than an
  omission. A harness is installed and runs on its own machine; lifecycle belongs
  where the process is. `Agents.stop_agent/2` exists and is deliberately not
  wired here.

  A Claude Code row also gets no reply box. There is no lane to route a
  `user_message` to, so the box would accept text and drop it — worse than no
  box, because the person believes they redirected an agent and finds out when
  the work comes back wrong.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Agents
  alias CodeMySpec.Conversations
  alias CodeMySpec.Harnesses

  @impl true
  def mount(_params, _session, socket), do: {:ok, assign(socket, :open_copy, nil)}

  @impl true
  def handle_params(_params, _uri, socket) do
    case socket.assigns[:project] do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "That project is not yours, or does not exist.")
         |> push_navigate(to: ~p"/app/projects")}

      _project ->
        if connected?(socket), do: Agents.subscribe(socket.assigns.current_scope)
        {:noreply, load(socket)}
    end
  end

  # Re-read on any agent news. The page's whole claim is about what is running
  # right now, and a report is the only moment the server learns an agent went.
  @impl true
  def handle_info({event, _payload}, socket)
      when event in [:agents_reported, :agent_started, :agent_stopped] do
    {:noreply, load(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def handle_event("open_transcript", %{"root" => root}, socket) do
    {:noreply, socket |> assign(:open_copy, root) |> load()}
  end

  def handle_event("rename", %{"root" => root, "label" => label}, socket) do
    socket.assigns.current_scope
    |> Harnesses.list_harnesses()
    |> Enum.find(&(&1.root == root))
    |> rename(socket.assigns.current_scope, label)

    {:noreply, load(socket)}
  end

  def handle_event("send_message", %{"message" => message}, socket) do
    socket.assigns.rows
    |> Enum.find(&(&1.harness.root == socket.assigns.open_copy))
    |> reply(message)

    {:noreply, load(socket)}
  end

  defp rename(nil, _scope, _label), do: :ok
  defp rename(harness, scope, label), do: Harnesses.relabel(scope, harness, label)

  defp reply(nil, _message), do: :ok
  defp reply(%{conversation: nil}, _message), do: :ok

  defp reply(%{conversation: conversation}, message),
    do: Conversations.add_agent_message(conversation, "operator", "text", message)

  defp load(socket) do
    scope = socket.assigns.current_scope
    agents = Agents.list_running(scope)

    rows =
      scope
      |> Harnesses.list_harnesses()
      |> Enum.map(&row(&1, agents, scope, socket.assigns.project))

    assign(socket, :rows, rows)
  end

  defp row(harness, agents, scope, project) do
    agent = Enum.find(agents, &(&1.working_copy == harness.root))

    %{
      harness: harness,
      label: harness.label || harness.root,
      agent: agent,
      conversation: conversation(agent, scope, project, harness.root),
      messages: []
    }
    |> load_messages()
  end

  # A conversation per working copy, found or made here rather than only when
  # *we* start an agent. The harness starts its own — that is the ordinary case,
  # not the exception — and an agent whose transcript does not exist cannot be
  # read or answered. Keyed `pi:<root>`, the same key a lane pushes under, so
  # both routes land on one thread instead of two.
  #
  # Not in `render/1`: this writes on first sight, and a render that writes runs
  # on every diff.
  defp conversation(nil, _scope, _project, _root), do: nil

  defp conversation(_agent, scope, project, root) do
    case Conversations.find_or_create_agent_conversation(
           scope.active_account_id,
           project.id,
           "pi:#{root}"
         ) do
      {:ok, conversation} -> conversation
      _ -> nil
    end
  end

  defp load_messages(%{conversation: nil} = row), do: row

  defp load_messages(%{conversation: conversation} = row),
    do: %{row | messages: Conversations.list_messages(conversation)}

  # "Idle" rather than "no agent running": the row has to say something, and the
  # obvious phrasing contains the word this row exists to stop claiming.
  defp liveness(%{agent: nil}), do: "Idle"
  defp liveness(%{agent: %{engine: :pi}}), do: "Present"

  defp liveness(%{agent: %{updated_at: at}}),
    do: "Last heard from #{Calendar.strftime(at, "%b %-d, %H:%M")}"

  # A message's content is a list of typed parts, not a string — the same
  # envelope a tool call travels in. Only the text parts are readable here; a
  # tool call rendered raw is a map printed at somebody.
  defp message_text(%{content: parts}) when is_list(parts),
    do: parts |> Enum.filter(&is_map/1) |> Enum.map_join(" ", &part_text/1)

  defp message_text(%{content: content}) when is_binary(content), do: content
  defp message_text(_message), do: ""

  defp part_text(%{"text" => text}) when is_binary(text), do: text
  defp part_text(%{text: text}) when is_binary(text), do: text
  defp part_text(_part), do: ""

  defp talkable?(%{agent: %{engine: :pi}}), do: true
  defp talkable?(_row), do: false

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div data-test="working-copies" class="mx-auto w-full max-w-3xl">
        <h1 class="text-xl font-semibold">Working copies</h1>
        <p class="mt-1 text-sm opacity-70">
          Every checkout serving this project, and what is running on it. A working
          copy is a harness — same id, two names.
        </p>

        <p :if={@rows == []} data-test="working-copies-empty" class="py-16 text-center opacity-60">
          No working copies yet. One appears when a harness connects for this project.
        </p>

        <ul class="mt-6 space-y-3">
          <li
            :for={row <- @rows}
            data-test="working-copy"
            data-root={row.harness.root}
            class="card card-compact border border-base-300 bg-base-100"
          >
            <div class="card-body gap-2">
              <div class="flex items-center gap-3">
                <div class="min-w-0 flex-1">
                  <div class="font-medium truncate">{row.label}</div>
                  <div class="text-xs opacity-60 truncate">{row.harness.root}</div>
                </div>

                <div data-test="liveness" class="text-sm shrink-0">{liveness(row)}</div>

                <button
                  :if={row.agent}
                  type="button"
                  data-test="open-transcript"
                  phx-click="open_transcript"
                  phx-value-root={row.harness.root}
                  class="btn btn-sm btn-ghost shrink-0"
                >
                  Transcript
                </button>
              </div>

              <form
                phx-submit="rename"
                class="flex items-center gap-2"
              >
                <input type="hidden" name="root" value={row.harness.root} />
                <input
                  type="text"
                  name="label"
                  value={row.harness.label}
                  placeholder="name this copy"
                  data-test="rename"
                  class="input input-xs input-bordered min-w-0 flex-1"
                />
                <button type="submit" class="btn btn-xs">Save</button>
              </form>

              <div :if={@open_copy == row.harness.root} class="mt-2 space-y-2">
                <div data-test="agent-transcript" class="rounded bg-base-200 p-2 text-sm">
                  <p :for={message <- row.messages} class="py-0.5">
                    {message_text(message)}
                  </p>
                </div>

                <form
                  :if={talkable?(row)}
                  data-test="agent-reply"
                  phx-submit="send_message"
                  class="flex items-center gap-2"
                >
                  <input
                    type="text"
                    name="message"
                    placeholder="say something to this agent"
                    class="input input-sm input-bordered min-w-0 flex-1"
                  />
                  <button type="submit" class="btn btn-sm btn-primary">Send</button>
                </form>
              </div>
            </div>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end
end
