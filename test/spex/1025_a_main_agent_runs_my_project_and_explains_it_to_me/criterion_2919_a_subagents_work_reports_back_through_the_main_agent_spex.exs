defmodule CodeMySpecSpex.Story963.Criterion2919Spex do
  @moduledoc """
  Story 963 — A main agent runs my project and explains it to me.
  Criterion 2919 — A subagent's work reports back through the main agent.

  Rule: Work the main agent delegates does not become a second conversation with the user.

  The PM's example was persona research, and his decision was that this story
  does not build delegation — the rule exists so nothing built now makes it
  impossible later.

  ## What a spex can assert here, and what it cannot

  This criterion is about what the agent *says*. A spex drives surfaces, not a
  model, so it cannot assert prose — and a check dressed up to look as though
  it does would go green while the thing the criterion cares about was wrong.

  So this asserts that the user is offered one thread for the project however many agents are running on it. What a subagent reports, since none exists yet is left to QA, where a person reads
  what the agent actually said.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
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

  spex "Work the main agent delegates does not become a second conversation with the user" do
    scenario "A subagent's work reports back through the main agent" do
      given_ "the main agent has delegated something like persona research", context do
        copy = CodeMySpec.TempFile.dir("spex_2919")
        File.mkdir_p!(copy)
        joined = join_working_copy(context, copy, "the main checkout")

        {:ok, live, _html} =
          live(
            context.conn,
            ~p"/app/projects/#{context.project.id}/working-copies/#{joined.working_copy_id}"
          )

        live |> element("[data-test=designate-main-copy]") |> render_click()

        other = CodeMySpec.TempFile.dir("spex_2919_other")
        File.mkdir_p!(other)
        Fixtures.running_agent(context.scope, working_copy: other)

        {:ok, context}
      end

      when_ "that work finishes", context do
        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "the main agent tells me about it in the conversation we were already having",
            context do
        assert context.html =~ "data-test=\"main-agent\"",
               "there is no main conversation for delegated work to report back into"

        {:ok, context}
      end

      then_ "and I am not given a second thread to follow", context do
        threads = Regex.scan(~r/data-test="main-agent"/, context.html)

        assert length(threads) == 1,
               "the user is offered #{length(threads)} threads. Delegation that becomes " <>
                 "a second conversation puts the reader back to following several " <>
                 "agents, which is what the main agent exists to stop."

        {:ok, context}
      end
    end
  end
end
