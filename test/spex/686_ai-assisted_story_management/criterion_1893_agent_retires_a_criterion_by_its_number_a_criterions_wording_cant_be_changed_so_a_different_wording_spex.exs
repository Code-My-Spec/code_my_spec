defmodule CodeMySpecSpex.Story686.Criterion1893Spex do
  @moduledoc """
  Story 686 — AI-Assisted Story Management
  Criterion 1893 — Agent retires a criterion by its number; a criterion's
  wording can't be changed, so a different wording is a new criterion.

  Title-only criterion; no scenario was recorded against it. Driven directly
  from the title, in three parts: retiring by number drops a criterion from
  the story's coverage without deleting or reassigning its number
  (`retire_criterion`'s own doc: "There is no delete"); there is no tool to
  rewrite a criterion's wording in place (`CodeMySpec.Stories.Tools.all/0`
  lists no `update_criterion`); and a corrected wording is added as a new
  criterion, standing beside the old one rather than replacing it.

  Surface: `retire_criterion`, `get_story`, `get_criterion`, and
  `add_criterion` MCP tools.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame
  alias CodeMySpecSpex.StoryHelpers

  import CodeMySpecSpex.TaskResponseHelpers, only: [response_text: 1]

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Agent retires a criterion by its number; wording can't be changed in place",
    criterion: 1893 do
    scenario "Retiring a criterion drops it from the story, without deleting its number" do
      given_ "a story exists with one criterion", context do
        story =
          StoryHelpers.create_story(context.scope,
            title: "Story with a retirable criterion",
            description: "Holds one criterion that will be retired by its number.",
            acceptance_criteria: ["Players have a discrete age"]
          )

        [criterion] = story.criteria

        {:ok, context |> Map.put(:story, story) |> Map.put(:criterion, criterion)}
      end

      when_ "the agent calls retire_criterion with that criterion's number", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "retire_criterion",
            %{criterion_number: context.criterion.id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, response),
               "expected retire_criterion to succeed, got: #{inspect(response)}"

        {:ok, context}
      end

      then_ "the retired criterion no longer appears in the story's coverage", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        get_response =
          ToolLibrary.run(
            "get_story",
            %{story_number: context.story.number},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        body = response_text(get_response)

        refute body =~ "Players have a discrete age",
               "expected the retired criterion to be gone from get_story, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "the criterion's own number still reads back, retired, by get_criterion", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        criterion_response =
          ToolLibrary.run(
            "get_criterion",
            %{criterion_number: context.criterion.id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, criterion_response),
               "expected the retired criterion's own number to still read back via " <>
                 "get_criterion, got: #{inspect(criterion_response)}"

        {:ok, context}
      end
    end

    scenario "There is no tool to rewrite a criterion's wording in place" do
      given_ "a story exists with one criterion", context do
        story =
          StoryHelpers.create_story(context.scope,
            title: "Story with an unchangeable criterion",
            description: "Holds one criterion whose wording cannot be edited.",
            acceptance_criteria: ["Players have a discrete age"]
          )

        [criterion] = story.criteria

        {:ok, context |> Map.put(:story, story) |> Map.put(:criterion, criterion)}
      end

      when_ "the agent attempts to change that criterion's wording directly", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "update_criterion",
            %{
              criterion_number: context.criterion.id,
              description: "Players have a continuous age"
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :update_attempt, response)}
      end

      then_ "the attempt is refused -- no such tool exists", context do
        assert {:error, _} = context.update_attempt,
               "expected no tool to rewrite a criterion's wording, got: #{inspect(context.update_attempt)}"

        {:ok, context}
      end

      then_ "the criterion's original wording is unchanged on the story", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        get_response =
          ToolLibrary.run(
            "get_story",
            %{story_number: context.story.number},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        body = response_text(get_response)

        assert body =~ "Players have a discrete age",
               "expected the original wording to still be on the story, got: #{inspect(body)}"

        refute body =~ "Players have a continuous age",
               "expected no in-place rewrite of the criterion's wording, got: #{inspect(body)}"

        {:ok, context}
      end
    end

    scenario "A different wording stands beside the old one as a new criterion, not a replacement" do
      given_ "a story exists with one criterion", context do
        story =
          StoryHelpers.create_story(context.scope,
            title: "Story that gains a differently-worded criterion",
            description: "The new wording must be a second criterion, not an edit.",
            acceptance_criteria: ["Players have a discrete age"]
          )

        [criterion] = story.criteria

        {:ok, context |> Map.put(:story, story) |> Map.put(:original_criterion, criterion)}
      end

      when_ "the agent adds a criterion with the differently-worded text", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "add_criterion",
            %{story_number: context.story.number, description: "Players have a continuous age"},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, response),
               "expected add_criterion to succeed, got: #{inspect(response)}"

        {:ok, context}
      end

      then_ "the story now shows both wordings as two distinct criteria", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        get_response =
          ToolLibrary.run(
            "get_story",
            %{story_number: context.story.number},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        body = response_text(get_response)

        assert body =~ "Players have a discrete age",
               "expected the original criterion to remain, got: #{inspect(body)}"

        assert body =~ "Players have a continuous age",
               "expected the differently-worded criterion to appear as its own entry, " <>
                 "got: #{inspect(body)}"

        [new_number] =
          Regex.run(~r/- \[ \] Players have a continuous age \(criterion (\d+)\)/, body,
            capture: :all_but_first
          )

        refute String.to_integer(new_number) == context.original_criterion.id,
               "the new wording must be a new criterion, not a rewrite sharing the original's " <>
                 "number #{context.original_criterion.id}, got: #{inspect(body)}"

        {:ok, context}
      end
    end
  end
end
