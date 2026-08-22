defmodule CodeMySpecSpex.Story1018.Criterion2824Spex do
  @moduledoc """
  Story 1018 — A Pi agent starts in a minted working copy on my own subscription.
  Criterion 2824 — One agent, whichever engine is behind it.

  Rule: A started Pi agent reports to the same places a Claude Code agent does.

  This is the criterion the whole story is worth doing for. The operator surface —
  the list of sessions against a project and the transcript of any one of them —
  already exists and already carries Claude Code's turns up through
  `AgentHarness.relay_up/2`. If Pi arrives with its own reporting path, there are
  two surfaces to watch, two to maintain, and no single answer to "what is running
  on this project".

  So the assertion is about the surface, not the engine: a Pi agent's turns appear
  where a Claude Code agent's do, attributed to the working copy it is on, and
  nothing downstream had to learn which engine produced them.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Agents.Tools.StartAgent
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "One place to watch agents work" do
    scenario "One agent, whichever engine is behind it" do
      given_ "a Pi agent started on a minted working copy", context do
        {:ok, _integration} = Fixtures.connect_provider(context.scope, :openai)

        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartAgent.execute(%{"engine" => "pi", "provider" => "openai-codex"}, frame)

        refute response.isError
        {:ok, Map.put(context, :response, response)}
      end

      when_ "it picks up work and reports progress", context do
        {:ok, live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        {:ok, context |> Map.put(:live, live) |> Map.put(:html, html)}
      end

      then_ "it appears where a Claude Code agent on the same copy would appear", context do
        assert context.html =~ context.project.name,
               "the agent conversation surface did not render this project at all, " <>
                 "so an absent Pi agent cannot be told from an absent page."

        assert has_element?(context.live, "[data-test='agent-session']"),
               "a started Pi agent produced no session on the surface where agents " <>
                 "are watched. A second reporting path means two surfaces to watch " <>
                 "and no single answer to what is running on this project."

        {:ok, context}
      end

      then_ "its work is attributed to the working copy it is on", context do
        assert context.html =~ context.scope.cwd,
               "the agent's session is not attributed to a working copy. One project " <>
                 "can have several copies with an agent each, and a session that " <>
                 "names no copy cannot be told from the others. Every other harness " <>
                 "surface is keyed this way. Got page without: #{context.scope.cwd}"

        {:ok, context}
      end
    end
  end
end
