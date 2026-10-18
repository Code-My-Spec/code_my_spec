defmodule CodeMySpecSpex.Story1062.Criterion3503Spex do
  @moduledoc """
  Story 1062 — The graph recomputes as observations arrive.
  Criterion 3503 — A story changing reaches every checkout.

  Rule: a writer says whether what it moved is about one checkout or about the
  whole project.

  ## The other half of 3506, and it fails in the opposite direction

  Criterion 3506 asserts that a file sync moves only the checkout it happened
  in. On its own that claim is satisfied by a projector that narrows everything
  to the writer's checkout — which is wrong, and wrong silently.

  A story is not a checkout's. Every checkout reads the same story row, so
  linking one to a component moves what all of them answer about it. An agent
  doing that from inside its own worktree has an active checkout on its scope,
  and taking the vantage from there would settle that worktree and leave every
  other one answering about a story that no longer exists in that shape.

  That is not hypothetical: it is the bug this spex was written against. The
  writer declares `:project_wide` rather than inheriting its scope, precisely
  because the scope cannot tell "I am speaking about this checkout" from "I
  happen to be standing in it".

  ## Why `component_linked` is the verdict read

  It is the one a story change moves that both checkouts can see. `story_changed`
  dirties the `:links` profile, `component_linked` reads it, and the answer
  depends on the story row alone — not on any file, so it cannot move for the
  incidental reason that one checkout has a tree and the other does not.

  Creation is deliberately not the trigger. `story_created` falls back to a
  recompute by design — handlers settle rows and cannot write ones that do not
  exist yet — so a criterion built on it would pass without any of the routing
  under test running at all.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  import CodeMySpecSpex.GraphReadHelpers
  import CodeMySpecSpex.SharedGivens
  import CodeMySpecSpex.StoryHelpers, only: [create_story: 2]
  import CodeMySpecSpex.WorkingCopyHelpers

  alias Anubis.Server.Frame

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A story belongs to the project, so its change reaches every checkout", criterion: 1415 do
    scenario "A story changing reaches every checkout" do
      given_(:synced_context_component)

      given_ "a story that is not linked to anything yet", context do
        story =
          create_story(context.scope,
            title: "Unlinked",
            description: "so that linking it is a change with somewhere to go"
          )

        {:ok, context |> Map.put(:story_id, story.id) |> Map.put(:story_number, story.number)}
      end

      given_ "a second checkout on the same project", context do
        second_root = CodeMySpec.TempFile.owned_dir("test")
        {reply, _socket} = join_working_copy_socket(context, second_root, "the second checkout")
        second_id = reply["harness_id"] || reply[:working_copy_id]

        refute second_id == context.scope.active_working_copy_id,
               "two checkouts must be two copies; the server issued one id for both"

        {:ok,
         context
         |> Map.put(:second_id, second_id)
         |> Map.put(:first_id, context.scope.active_working_copy_id)}
      end

      given_ "neither checkout says the story is linked", context do
        # given: already true — `create_story/2` above makes a story with no
        # component, and nothing between here and there links one. This block
        # establishes nothing on purpose: it exists to prove the baseline before
        # the when_ moves it, because "both checkouts say linked" would pass the
        # assertions below for a story that was linked all along.
        first = linked?(read_settled_graph(context, context.first_id), context.story_id)
        second = linked?(read_settled_graph(context, context.second_id), context.story_id)

        assert first == false and second == false,
               """
               This story is supposed to start unlinked from both checkouts, or
               the assertion below is measuring something that was already true.

               first: #{inspect(first)}  second: #{inspect(second)}
               """

        {:ok, context}
      end

      when_ "the story is linked to a component from one checkout", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        reply =
          ToolLibrary.run(
            "set_story_component",
            %{story_number: context.story_number, module_name: "ExampleContext"},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, reply), inspect(reply)

        {:ok,
         context
         |> Map.put(
           :first_after,
           linked?(read_settled_graph(context, context.first_id), context.story_id)
         )
         |> Map.put(
           :second_after,
           linked?(read_settled_graph(context, context.second_id), context.story_id)
         )}
      end

      then_ "the checkout it was done from says so", context do
        assert context.first_after == true,
               "the story was linked from this checkout and it still answers #{inspect(context.first_after)}"

        {:ok, context}
      end

      then_ "and so does the checkout that had nothing to do with it", context do
        assert context.second_after == true,
               """
               A story was linked and this checkout still answers
               #{inspect(context.second_after)}.

               The change was narrowed to the checkout whose agent happened to
               make it. A story is not a checkout's — every checkout reads the
               same row — so every one of them has to be settled, and this one
               is left telling agents a story is unlinked when it is not.
               """

        {:ok, context}
      end
    end
  end

  # What a checkout says about `component_linked` for one story: `true`, `false`,
  # or `nil` when the requirement is not projected there at all. `nil` is a real
  # answer and a different failure from `false`, so it is not folded into it.
  defp linked?(graph, story_id) do
    (graph["nodes"] || [])
    |> Enum.find(
      &(&1["entity_type"] == "story" and to_string(&1["entity_id"]) == to_string(story_id) and
          &1["name"] == "component_linked")
    )
    |> verdict_of()
  end

  defp verdict_of(nil), do: nil
  defp verdict_of(node), do: node["satisfied"]
end
