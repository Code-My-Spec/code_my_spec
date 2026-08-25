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
  import CodeMySpecSpex.WorkingCopyHelpers

  import CodeMySpecSpex.AgentProcessHelpers

  alias CodeMySpecSpex.Fixtures
  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

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
        copy = CodeMySpec.TempFile.dir("spex_2917")
        File.mkdir_p!(copy)
        joined = join_working_copy(context, copy, "the main checkout")

        {:ok, live, _html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/working-copies/#{joined.working_copy_id}"
          )

        live |> element("[data-test=designate-main-copy]") |> render_click()

        {:ok, chat, _html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        chat
        |> form("form[phx-submit=send_message]", %{"message" => "the thing we agreed"})
        |> render_submit()

        {:ok, _live, before} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        {:ok, context |> Map.put(:copy, copy) |> Map.put(:before, before)}
      end

      when_ "the machine running it restarts", context do
        id = agent_id(context.before)

        assert id, "the premise is a running main agent; the page names none"

        stop_agent_process(id)
        restore_agent(id, context.copy)

        {:ok, Map.put(context, :agent, id)}
      end

      then_ "the main agent comes back to that same conversation", context do
        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        assert conversation_id(html) == conversation_id(context.before),
               "the restart landed on a different conversation, so the history is in " <>
                 "the one nobody is reading"

        assert html =~ "the thing we agreed",
               "the conversation came back empty"

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

  defp agent_id(html) do
    case Regex.run(~r/data-test="main-agent"[^>]*data-agent-id="([^"]+)"/, html) do
      [_, id] -> id
      nil -> nil
    end
  end

  defp conversation_id(html) do
    case Regex.run(~r"/agent-conversation/([0-9a-f-]{36})", html) do
      [_, id] -> id
      nil -> nil
    end
  end
end
