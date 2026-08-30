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

  spex "Every project has exactly one main agent" do
    scenario "Opening a project finds its main agent" do
      given_ "a project I own", context do
        copy = CodeMySpec.TempFile.dir("spex_2902")
        File.mkdir_p!(copy)
        joined = join_working_copy(context, copy, "the main checkout")

        designate_main_copy(context, joined.working_copy_id)

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

        assert agent_id_in(html) == agent_id_in(context.html),
               "opening the project twice found two different agents. An agent that " <>
                 "is a different agent each time cannot hold the project's history, " <>
                 "which is the whole reason this one exists."

        {:ok, context}
      end

      # Stopping is story 961's whole point, and opening the project afterwards
      # is the same act this criterion is about. It used to find nothing and
      # start nothing: `main_agent/1` read every agent ever started, so the
      # stopped one still counted as the agent on the copy, `ensure_main_agent/1`
      # short-circuited on it, and the checkout could never hold another. The
      # page went on saying it was getting ready, forever.
      then_ "and opening it after stopping that agent finds a new one", context do
        stop_main_agent(context)

        {:ok, _after_stop, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        assert html =~ "data-test=\"main-agent\"",
               "stopping the main agent left the project with none, and opening it " <>
                 "did not start one. The one agent a non-technical user knows about " <>
                 "cannot be a thing they can permanently destroy by using its stop " <>
                 "button."

        refute agent_id_in(html) == agent_id_in(context.html),
               "the stopped agent was handed back as the project's agent. It is not " <>
                 "running, so nothing will answer, and the page says it is getting ready."

        {:ok, context}
      end
    end
  end

end
