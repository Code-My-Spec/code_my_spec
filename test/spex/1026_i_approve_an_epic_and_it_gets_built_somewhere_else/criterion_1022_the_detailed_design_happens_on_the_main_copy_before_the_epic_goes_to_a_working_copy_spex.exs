defmodule CodeMySpecSpex.Story964.Criterion2935Spex do
  @moduledoc """
  Story 964 — I approve an epic and it gets built somewhere else.
  Criterion 2935 — The detailed design happens on the main copy, before the epic
  goes to a working copy.

  Rule: Product does an epic's detailed design on the main copy; the approved
  epic then goes to a working copy, where coding and QA build it.

  John, a31f1cd6 step 4c: product lives on the main copy, owns three amigos and
  story design, and holds one chain of thought through the whole design. The
  feature copy's team builds what was designed; it is not where the design is
  done.
  """

  use CodeMySpecSpex.Case

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias CodeMySpecSpex.EpicHelpers
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.MainAgentHelpers
  alias CodeMySpecSpex.ProjectStateFixtures
  alias Ecto.Adapters.SQL.Sandbox

  cloud_endpoint()

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Product does an epic's detailed design on the main copy; the approved epic then goes to a working copy, where coding and QA build it",
    criterion: 1022 do
    scenario "The detailed design happens on the main copy, before the epic goes to a working copy" do
      given_ "the project has completed kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a main checkout with the product agent on it", context do
        context = MainAgentHelpers.given_a_main_checkout(context, "spex_1022_main")
        main_scope = %{context.scope | active_working_copy_id: context.copy_id}
        product = Fixtures.running_agent(main_scope, role: "product", continuous: true)
        {:ok, Map.merge(context, %{main_scope: main_scope, product: product})}
      end

      given_ "an epic proposed but not yet approved", context do
        epic_id = EpicHelpers.propose(context, "Six things to build", stories: 2)
        {:ok, Map.put(context, :epic, epic_id)}
      end

      when_ "the product agent asks what to work on", context do
        frame = %Frame{
          assigns: %{current_scope: context.main_scope, agent_id: context.product.id}
        }

        {:reply, response, _} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :answer, response_text(response))}
      end

      then_ "it is offered the Three Amigos on the epic's stories, on the main copy", context do
        assert context.answer =~ "three_amigos_complete",
               "product on the main copy was not offered the epic's design:\n#{context.answer}"

        {:ok, context}
      end

      then_ "and the epic has not gone to a working copy yet", context do
        {:ok, _live, epics} = live(context.conn, ~p"/app/projects/#{context.project.id}/epics")

        refute epics =~ ~s(data-test="epic-working-copy"),
               "the epic was placed on a working copy before its design was done"

        {:ok, context}
      end
    end
  end
end
