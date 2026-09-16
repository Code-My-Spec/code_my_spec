defmodule CodeMySpecSpex.Story963.Criterion2917Spex do
  @moduledoc """
  Story 963 — A main agent runs my project and explains it to me.
  Criterion 2917 — A restart does not cost the conversation.

  Rule: The main agent picks up the same conversation every time, however long it has been.

  The failure mode with teeth. An agent dies with its harness — that is stated
  in `CmsHarness.Agents.Engine` and accepted, because the transcript is the
  state and coming back is starting a process with the history it had.

  For a working-copy agent that is a turn lost. For the main agent it would be
  the project's whole conversation, and worse: a restart that mints a second
  conversation leaves two, with the history in the one nobody is reading.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.MainAgentHelpers

  import CodeMySpecSpex.AgentProcessHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  cloud_endpoint()

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  # The agent runs on a provider, and refusing without one is deliberate — an
  # agent started on a credential that does not resolve fails on its first
  # model call, minutes later, in a log nobody reads.
  setup %{scope: scope} do
    Fixtures.connect_provider(scope, :openai)
    :ok
  end

  spex "The main agent picks up the same conversation every time, however long it has been" do
    scenario "A restart does not cost the conversation" do
      given_ "a conversation with the main agent", context do
        context = given_a_main_checkout(context, "spex_2917")
        path = say_to_main_agent(context, "the thing we agreed")

        {:ok, _live, before} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        {:ok, context |> Map.put(:path, path) |> Map.put(:before, before)}
      end

      when_ "the machine running it restarts", context do
        id = agent_id_in(context.before)

        assert id, "the premise is a running main agent; the page names none"

        # Through the harness's own restore rather than a start built here. The
        # refusals a restore inherits — a checkout that is gone, a credential
        # nobody can resolve, a history that never travelled — are only real if
        # the same code path produces them.
        stop_agent_process(id)
        restart_harness(context.harness_socket)

        {:ok, Map.put(context, :agent, id)}
      end

      then_ "the main agent comes back to that same conversation", context do
        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        assert conversation_id(html) == conversation_id(context.before),
               "the restart landed on a different conversation, so the history is in " <>
                 "the one nobody is reading"

        {:ok, _live, transcript} = live(context.conn, context.path)

        assert transcript =~ "the thing we agreed",
               "the conversation came back empty"

        assert agent_knows?(main_agent_id(context), "the thing we agreed"),
               "the agent came back to the conversation without coming back to what is " <>
                 "in it. It will be read the transcript by the person who already knows " <>
                 "what it says, which is the cost the restart was supposed not to have."

        {:ok, Map.put(context, :html, html)}
      end

      then_ "and no second conversation is created alongside it", context do
        threads = Regex.scan(~r/data-test="main-agent"/, context.html)

        assert length(threads) == 1,
               "there are #{length(threads)} main conversations after a restart. Two " <>
                 "is worse than none: the user reads the empty one and concludes the " <>
                 "project has no history."

        {:ok, context}
      end
    end
  end

  defp conversation_id(html) do
    ~r"/agent-conversation/([0-9a-f-]{36})"
    |> Regex.run(html)
    |> conversation_id_match()
  end

  defp conversation_id_match([_, id]), do: id
  defp conversation_id_match(nil), do: nil
end
