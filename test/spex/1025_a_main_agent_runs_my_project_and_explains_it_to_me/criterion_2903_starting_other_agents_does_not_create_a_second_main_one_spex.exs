defmodule CodeMySpecSpex.Story963.Criterion2903Spex do
  @moduledoc """
  Story 963 — A main agent runs my project and explains it to me.
  Criterion 2903 — Starting other agents does not create a second main one.

  Rule: Every project has exactly one main agent.

  The failure the "exactly one" rule exists for. `start_agent` mints an agent
  per working copy and every one of them carries `role: "main"` — the column
  defaults to it — so a project that starts three agents has three rows calling
  themselves main and nothing that says which one the user talks to.

  Being the main agent is a property of the project, not a word on a row.
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
    scenario "Starting other agents does not create a second main one" do
      given_ "a project whose main agent is running", context do
        copy = CodeMySpec.TempFile.dir("spex_2903")
        File.mkdir_p!(copy)
        joined = join_working_copy(context, copy, "the main checkout")

        designate_main_copy(context, joined.working_copy_id)

        {:ok, live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        assert html =~ "data-test=\"main-agent\"",
               "the premise is a project that has a main agent; without one this " <>
                 "criterion cannot tell a second from a first"

        {:ok, context |> Map.put(:live, live) |> Map.put(:before, html)}
      end

      when_ "agents are started on its working copies", context do
        copy = CodeMySpec.TempFile.dir("spex_2903")
        File.mkdir_p!(copy)

        one = Fixtures.running_agent(context.scope, working_copy: copy)
        two = Fixtures.running_agent(context.scope, working_copy: copy)

        {:ok, context |> Map.put(:started, [one, two])}
      end

      then_ "the project still presents exactly one main agent", context do
        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        markers = Regex.scan(~r/data-test="main-agent"/, html)

        assert length(markers) == 1,
               "the project presents #{length(markers)} main agents. Every agent row " <>
                 "carries role \"main\" by default, so without something that makes one " <>
                 "of them *the* one, starting work anywhere invents a second."

        {:ok, Map.put(context, :html, html)}
      end

      then_ "and it is the one it presented before", context do
        assert context.html =~ "data-test=\"main-agent\""

        refute context.html == "",
               "the page rendered nothing, so this cannot distinguish a stable main " <>
                 "agent from an absent one"

        {:ok, context}
      end
    end
  end
end
