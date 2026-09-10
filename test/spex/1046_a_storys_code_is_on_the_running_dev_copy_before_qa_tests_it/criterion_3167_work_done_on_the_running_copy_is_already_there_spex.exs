defmodule CodeMySpecSpex.Story1046.Criterion3167Spex do
  @moduledoc """
  Story 1046 — A story's code is on the running dev copy before QA tests it.
  Criterion 3167 — Work done on the running copy is already there.

  Rule: Work already on the running copy needs no promotion.

  John's objection to the first design, verbatim: "it is eminently possible
  that someone would be just doing the work on Maine." A gate that demands a
  merge from an agent already standing on the merge target is a deadlock —
  there is no branch to merge and nothing the agent can do to satisfy it.

  So the check is about the *state*, and an agent whose checkout is the running
  copy satisfies it by being there. No second checkout appears in this spec at
  all, which is the whole point: there is nothing to be in sync with.
  """

  use CodeMySpecSpex.Case

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.McpServers.Requirements.Tools.GetNextRequirement
  alias Ecto.Adapters.SQL.Sandbox

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "Work done on the running copy needs no promotion" do
    scenario "the agent is working in the checkout the application runs from" do
      given_ "a story ready for QA", context do
        # The chain first. Joining or designating a checkout before it leaves
        # the story short of `bdd_specs_passing`, and the graph then answers
        # with an earlier task instead of the node this criterion is about.
        {:ok, CodeMySpecSpex.FullSatisfactionFixtures.apply_without_qa_story(context)}
      end

      given_ "on the checkout the application runs from", context do
        {:ok, this_copy_is_the_running_one(context)}
      end

      when_ "the QA agent asks for its next work", context do
        frame = %Anubis.Server.Frame{assigns: %{current_scope: context.scope}}
        {:reply, response, _frame} = GetNextRequirement.execute(%{}, frame)
        {:ok, Map.put(context, :response, response)}
      end

      then_ "the story is ready for QA with no promotion asked for", context do
        text = response_text(context.response)

        assert text =~ "QaStory",
               "an agent working on the running copy was held behind a merge " <>
                 "it has no branch to make. Got: #{text}"

        refute text =~ "PromoteWork",
               "the agent was asked to promote work that is already where it goes"

        {:ok, context}
      end
    end
  end

  # Designate this checkout as the one the application runs from, through the
  # page that owns the choice. `main` is "designated, never inferred", so there
  # is no state to set behind the product's back.
  defp this_copy_is_the_running_one(context) do
    {:ok, view, _html} =
      live(context.conn, "/app/projects/#{context.project.id}/working-copies")

    view
    |> element(
      "[data-test='designate-main-copy'][phx-value-id='#{context.scope.active_working_copy_id}']"
    )
    |> render_click()

    context
  end
end
