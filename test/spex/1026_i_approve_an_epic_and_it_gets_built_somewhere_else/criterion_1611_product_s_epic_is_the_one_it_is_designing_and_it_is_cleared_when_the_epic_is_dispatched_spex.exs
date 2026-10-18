defmodule CodeMySpecSpex.Story964.Criterion1611Spex do
  @moduledoc """
  Story 964 — I approve an epic and it gets built somewhere else.
  Criterion 1611 — Product's epic is the one it is designing, and it is cleared
  when the epic is dispatched.

  a31f1cd6 step 4c/4d. Product designs an epic on the main copy; main, which
  dispatches epics, sees which one in `list_agent_work`. Once approved the epic
  goes to a feature copy's team and is no longer product's.
  """
  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import Phoenix.LiveViewTest
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.MainAgent.Tools.ListAgentWork
  alias CodeMySpec.Stories
  alias CodeMySpecSpex.EpicHelpers
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.MainAgentHelpers
  alias CodeMySpecSpex.ProjectStateFixtures
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  @epic "Checkout redesign"

  spex "Product's epic is the one it is designing, and it is cleared when the epic is dispatched",
    criterion: 1611 do
    scenario "Main sees product designing an epic, and not once it is approved" do
      given_ "the project has completed kickoff", context do
        {:ok, ProjectStateFixtures.apply_project_kickoff(context)}
      end

      given_ :synced_context_component

      given_ "a main checkout with the product agent on it", context do
        context = MainAgentHelpers.given_a_main_checkout(context, "spex_1611_main")
        main_scope = %{context.scope | active_working_copy_id: context.copy_id}
        product = Fixtures.running_agent(main_scope, role: "product", continuous: true)
        {:ok, Map.merge(context, %{main_scope: main_scope, product: product})}
      end

      given_ "an epic proposed but not yet approved", context do
        epic_id = EpicHelpers.propose(context, @epic, stories: 1)
        {:ok, Map.put(context, :epic, epic_id)}
      end

      when_ "product starts designing one of its stories", context do
        story = Stories.get_story!(context.scope, hd(EpicHelpers.story_ids(context.epic)))

        frame = %Frame{
          assigns: %{current_scope: context.main_scope, agent_id: context.product.id}
        }

        started =
          ToolLibrary.run(
            "start_task",
            %{
              requirement_name: "three_amigos_complete",
              entity_type: "story",
              entity_id: to_string(story.number)
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, started), response_text(started)
        {:ok, context}
      end

      then_ "main sees which epic product is designing", context do
        assert work(context) =~ "designing: #{@epic}",
               "main cannot see what product is designing:\n#{work(context)}"

        {:ok, context}
      end

      when_ "I approve the epic", context do
        {:ok, live, _html} = live(context.conn, ~p"/app/projects/#{context.project.id}/epics")

        live
        |> element(~s([data-test=approve-epic][data-epic-id="#{context.epic}"]))
        |> render_click()

        {:ok, context}
      end

      then_ "product is no longer shown designing it", context do
        refute work(context) =~ "designing: #{@epic}",
               "the epic went to a working copy and is still shown as product's:\n#{work(context)}"

        {:ok, context}
      end
    end
  end

  defp work(context) do
    {:reply, response, _} =
      ListAgentWork.execute(%{}, %Frame{assigns: %{current_scope: context.main_scope}})

    response_text(response)
  end
end
