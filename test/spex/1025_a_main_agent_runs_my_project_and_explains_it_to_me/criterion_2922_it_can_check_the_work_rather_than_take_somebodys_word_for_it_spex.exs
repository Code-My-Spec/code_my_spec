defmodule CodeMySpecSpex.Story963.Criterion2922Spex do
  @moduledoc """
  Story 963 — A main agent runs my project and explains it to me.
  Criterion 2922 — It can check the work rather than take somebody's word for it.

  Rule: The main agent has the run of the whole project — its records, its code, its tests and its problems.

  The CTO half of the role. The PM: "part of the main agent's responsibility
  is gonna be to make sure that these other subagents don't break the stuff."
  An agent that can only read what other agents claim cannot do that.

  ## What a spex can assert here, and what it cannot

  This criterion is about what the agent *says*. A spex drives surfaces, not a
  model, so it cannot assert prose — and a check dressed up to look as though
  it does would go green while the thing the criterion cares about was wrong.

  So this asserts that the agent runs somewhere its tools have a real checkout to act on, which is the precondition for checking anything. Whether it reads, runs and checks is left to QA, where a person reads
  what the agent actually said.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.MainAgentHelpers
  import CodeMySpecSpex.WorkingCopyHelpers

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.RealDisk
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

  spex "The main agent has the run of the whole project — its records, its code, its tests and its problems" do
    scenario "It can check the work rather than take somebody's word for it" do
      given_ "work has been done on my project", context do
        copy = CodeMySpec.TempFile.dir("spex_2922")
        RealDisk.mkdir_p!(copy)
        joined = join_working_copy(context, copy, "the main checkout")

        designate_main_copy(context, joined.working_copy_id)

        {:ok, context |> Map.put(:copy, copy) |> Map.put(:copy_id, joined.working_copy_id)}
      end

      when_ "I ask the main agent whether it is sound", context do
        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "it can read the code, run the tests and see the problems itself", context do
        assert context.html =~ context.copy_id,
               "the main agent is not running on the designated checkout, so it has " <>
                 "nothing to read, nothing to run and nothing to check"

        assert RealDisk.dir?(context.copy),
               "the checkout the main agent was pointed at is not there"

        {:ok, context}
      end

      then_ "and its answer rests on what it found rather than on what it was told",
            context do
        assert context.html =~ "data-test=\"main-agent\"",
               "there is no main agent to have found anything"

        {:ok, context}
      end
    end
  end
end
