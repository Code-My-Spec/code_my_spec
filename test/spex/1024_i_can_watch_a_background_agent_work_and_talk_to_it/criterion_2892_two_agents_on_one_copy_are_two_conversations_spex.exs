defmodule CodeMySpecSpex.Story1024.Criterion2892Spex do
  @moduledoc """
  Story 1024 — I can watch a background agent work and talk to it.
  Criterion 2892 — Two agents on one copy are two conversations.

  Rule: Every agent has its own conversation.

  This replaces a deliberate design rather than correcting a mistake.
  `Conversations.find_or_create_agent_conversation/3` keyed on the working copy
  and said so: "the shared id for the whole Pi team — the whole team's
  transcript lands here."

  That was reasonable when a copy ran one lane and the transcript was the
  copy's story. It is not reasonable now. Story 1023 keeps a rule about
  stopping one agent and leaving its siblings running, precisely because a copy
  runs several — and their turns interleaving into one thread means following
  either is impossible, and a reply cannot say who spoke.

  So the conversation belongs to the agent, which is the thing that has an id,
  can be started and stopped, and does the talking.

  ## Both agents have the same role, which is the real case

  `start_agent` takes no role, so every agent started through it is "main".
  Two rows keyed differently is only half the claim: QA found the working copy
  page rendering two links reading "Open main chat", one above the other,
  going to different conversations. An operator who picks the wrong one has
  redirected the agent they were not watching, and nothing on either page says
  so. So the page has to tell them apart too.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.AgentProcessHelpers
  import Phoenix.LiveViewTest

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.RealDisk
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A conversation belongs to an agent, not to a checkout" do
    scenario "Two agents on one copy are two conversations" do
      given_ "one working copy", context do
        copy = CodeMySpec.TempFile.dir("spex_2892")
        RealDisk.mkdir_p!(copy)

        # The scope's own copy, because that is the one an agent started here is
        # filed under. Joining a second one and opening that lists no agents,
        # which reads as the page failing and is the criterion looking at the
        # wrong checkout.
        {:ok, context |> Map.put(:copy, copy)}
      end

      when_ "two agents are started on it", context do
        # Both "main", because that is what `start_agent` produces and because
        # two agents that differ by role are the easy case.
        first = Fixtures.running_agent(context.scope, role: "main", working_copy: context.copy)
        second = Fixtures.running_agent(context.scope, role: "main", working_copy: context.copy)

        start_agent(first.id, working_copy: context.copy)
        start_agent(second.id, working_copy: context.copy)

        {:ok, context |> Map.put(:first, first) |> Map.put(:second, second)}
      end

      then_ "each has a conversation of its own", context do
        first_conversation = Fixtures.agent_conversation(context.scope, context.first)
        second_conversation = Fixtures.agent_conversation(context.scope, context.second)

        assert first_conversation, "the first agent has no conversation of its own"
        assert second_conversation, "the second agent has no conversation of its own"

        refute first_conversation.id == second_conversation.id,
               "both agents share one conversation. Their turns interleave into a " <>
                 "single thread, following either is impossible, and a reply cannot " <>
                 "say which of them spoke."

        assert first_conversation.agent_id == context.first.id,
               "the conversation does not name the agent it belongs to, so nothing " <>
                 "downstream can tell whose work it is holding"

        {:ok, context}
      end

      then_ "and the copy they share offers a way into each", context do
        {:ok, _live, html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/working-copies/#{context.scope.active_working_copy_id}"
          )

        links = Regex.scan(~r/data-test="open-agent-chat"[^>]*>([^<]*)</, html)
        labels = html |> Floki.parse_fragment!() |> Floki.find("[data-test=open-agent-chat]")

        assert length(labels) == 2,
               "the copy offers #{length(labels)} ways into #{2} agents' transcripts. " <>
                 "Two agents with one link means one of them cannot be reached from " <>
                 "the page that lists it. Found #{inspect(links)}"

        [one, two] = Enum.map(labels, &(&1 |> Floki.text() |> String.trim()))

        refute one == two,
               "both links read #{inspect(one)}. They go to different conversations, " <>
                 "which is worse than one link would be: an operator picks the wrong " <>
                 "one and has redirected the agent they were not watching."

        {:ok, context}
      end
    end
  end
end
