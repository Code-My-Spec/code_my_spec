defmodule CodeMySpecSpex.Story963.Criterion2923Spex do
  @moduledoc """
  Story 963 — A main agent runs my project and explains it to me.
  Criterion 2923 — Naming a different main copy moves the agent rather than replacing it.

  Rule: The main agent runs in the project's main working copy.

  The PM's answer to what happens on re-designation: "we would move the agent
  to the new checkout — that is in essence the same agent."

  Which is the version that keeps story 962's model rather than fighting it. A
  conversation belongs to an agent there, so an agent that survives the move
  carries its conversation with it and nothing has to be re-keyed onto the
  project. Replacing the agent instead would end a conversation of weeks because
  a directory changed.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest

  import CodeMySpecSpex.MainAgentHelpers
  import CodeMySpecSpex.WorkingCopyHelpers

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

  spex "The main agent runs in the project's main working copy" do
    scenario "Naming a different main copy moves the agent rather than replacing it" do
      given_ "a main agent I have been talking to for weeks", context do
        first = CodeMySpec.TempFile.dir("spex_2923_first")
        File.mkdir_p!(first)
        joined = join_working_copy(context, first, "where it started")

        designate_main_copy(context, joined.working_copy_id)

        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        {:ok, context |> Map.put(:before, html)}
      end

      when_ "a different working copy is designated the main one", context do
        second = CodeMySpec.TempFile.dir("spex_2923_second")
        File.mkdir_p!(second)
        joined = join_working_copy(context, second, "where it moves to")

        designate_main_copy(context, joined.working_copy_id)

        {:ok, context |> Map.put(:moved_to, joined.working_copy_id)}
      end

      then_ "the same agent is now running there", context do
        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        assert html =~ context.moved_to,
               "the main agent did not follow the designation"

        assert agent_id_in(html) == agent_id_in(context.before),
               "re-designating the main copy replaced the agent instead of moving it. " <>
                 "A conversation belongs to an agent, so a new agent means the weeks " <>
                 "of conversation before it are somebody else's."

        {:ok, Map.put(context, :html, html)}
      end

      then_ "and the conversation I have been having with it carries on", context do
        assert conversation_id(context.html) == conversation_id(context.before),
               "the conversation changed with the checkout, which is the loss this " <>
                 "criterion exists to prevent"

        {:ok, context}
      end
    end
  end

  defp conversation_id(html) do
    case Regex.run(~r"/agent-conversation/([0-9a-f-]{36})", html) do
      [_, id] -> id
      nil -> nil
    end
  end
end
