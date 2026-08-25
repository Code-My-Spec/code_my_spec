defmodule CodeMySpecSpex.Story963.Criterion2905Spex do
  @moduledoc """
  Story 963 — A main agent runs my project and explains it to me.
  Criterion 2905 — The main agent answers about the code that is actually there.

  Rule: The main agent runs in the project's main working copy.

  Where it runs decides what it can see. The PM chose the user's main checkout
  over a minted copy of its own, over no checkout at all, and over our
  infrastructure — because this agent is meant to read the code, run the tests
  and check the work, and none of that is possible from somewhere the code is
  not.

  ## What a spex can assert here, and what it cannot

  This criterion is about what the agent *says*. A spex drives surfaces, not a
  model, so it cannot assert prose — and a check dressed up to look as though
  it does would go green while the thing the criterion cares about was wrong.

  So this asserts that the agent runs in the checkout that was designated. Whether its answers draw on that code is left to QA, where a person reads
  what the agent actually said.
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
    scenario "The main agent answers about the code that is actually there" do
      given_ "a project whose main working copy is a checkout on my machine", context do
        copy = CodeMySpec.TempFile.dir("spex_2905")
        File.mkdir_p!(copy)
        joined = join_working_copy(context, copy, "the main checkout")

        designate_main_copy(context, joined.working_copy_id)

        {:ok, context |> Map.put(:copy, copy) |> Map.put(:copy_id, joined.working_copy_id)}
      end

      when_ "I ask the main agent what is in the project", context do
        {:ok, _live, html} =
          live(context.conn, ~p"/app/projects/#{context.project.id}/agent-conversation")

        {:ok, Map.put(context, :html, html)}
      end

      then_ "its answer is drawn from that checkout", context do
        assert context.html =~ context.copy_id,
               "the main agent is not running in the checkout that was designated, so " <>
                 "nothing it says about the code can be drawn from the code the user " <>
                 "means"

        {:ok, context}
      end
    end
  end
end
