defmodule CodeMySpecSpex.Story963.Criterion2902Spex do
  @moduledoc """
  Story 963 — A main agent runs my project and explains it to me.
  Criterion 2902 — Opening a project finds its main agent.

  Rule: Every project has exactly one main agent.

  The one agent a non-technical user has to know exists. Everything built so
  far is per working copy — 962 made an agent in a checkout watchable and
  answerable, 957 lists the checkouts — and all of it asks the user to know
  which checkout they mean before they can say anything.

  This asserts the opposite: you open a project and there is one thing to talk
  to, without choosing. And it is the same one tomorrow, because an agent that
  is a different agent each time cannot hold the project's history.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Every project has exactly one main agent" do
    scenario "Opening a project finds its main agent" do
      given_ "a project I own", context do
        {:ok, context}
      end

      when_ "I open it", context do
        {:ok, live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        {:ok, context |> Map.put(:live, live) |> Map.put(:html, html)}
      end

      then_ "there is one agent presented as the one to talk to", context do
        assert context.html =~ "data-test=\"main-agent\"",
               "the project offers no main agent, so a non-technical user has to pick " <>
                 "a checkout before they can say anything — which is the thing they " <>
                 "cannot be expected to know"

        {:ok, context}
      end

      then_ "and it is the same one the next time I open the project", context do
        {:ok, _again, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        assert html =~ "data-test=\"main-agent\"",
               "the main agent is gone on the second visit"

        assert main_agent_id(html) == main_agent_id(context.html),
               "opening the project twice found two different agents. An agent that " <>
                 "is a different agent each time cannot hold the project's history, " <>
                 "which is the whole reason this one exists."

        {:ok, context}
      end
    end
  end

  # The agent behind the marker, so "the same one" is a claim about identity
  # rather than about the marker being present twice.
  defp main_agent_id(html) do
    case Regex.run(~r/data-test="main-agent"[^>]*data-agent-id="([^"]+)"/, html) do
      [_, id] -> id
      nil -> nil
    end
  end
end
