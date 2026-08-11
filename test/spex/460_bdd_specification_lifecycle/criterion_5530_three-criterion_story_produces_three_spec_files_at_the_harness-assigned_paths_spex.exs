defmodule CodeMySpecSpex.Story460.Criterion5530Spex do
  @moduledoc """
  Story 460 — BDD Specification Lifecycle
  Criterion 5530 — Three-criterion story produces three spec files at
  the harness-assigned paths.

  When `start_task` runs for `bdd_specs_exist` on a story with three
  acceptance criteria, the prompt the agent receives names exactly
  three distinct spec file paths — one per criterion, all in a single
  story directory under `test/spex/`. Mirrors the prompt-content
  pattern in `559_three_amigos/criterion_5893_*`.

  Setup goes through the surface: `:synced_context_component` writes a
  spec + impl into the env and clicks the sync button; `StoryHelpers`
  drives the `CreateStory` and `SetStoryComponent` MCP tools to land
  the story and link it.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.SharedGivens

  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Three-criterion story produces three spec paths in the start_task prompt" do
    scenario "prompt names each criterion's harness-assigned path under the story directory" do
      given_ :synced_context_component

      given_ "a story with three criteria is linked to the synced component", context do
        story =
          StoryHelpers.create_and_link(context.scope, context.component.module_name,
            title: "Three-criterion BDD spec story",
            description: "Used for the three-path prompt assertion.",
            acceptance_criteria: [
              "first acceptance criterion text",
              "second acceptance criterion text",
              "third acceptance criterion text"
            ]
          )

        {:ok, Map.put(context, :story, story)}
      end

      given_ :bdd_task_started

      then_ "the prompt names exactly three harness-assigned paths under the story directory",
            context do
        prompt = context.prompt

        expected_paths =
          Enum.map(context.story.criteria, fn criterion ->
            Fixtures.spec_file_path(context.story, criterion)
          end)

        assert length(expected_paths) == 3,
               "expected 3 criteria, got #{length(expected_paths)}"

        for path <- expected_paths do
          assert prompt =~ path,
                 "expected prompt to mention `#{path}`, got prompt:\n#{prompt}"
        end

        # One directory, three files. This used to assert the directory was
        # named `test/spex/<story.id>_`, which stopped being true when the
        # story's durable number replaced its primary key in the path — the id
        # renumbers on migration and the directories named from it stopped
        # pointing at the stories they were written for. The criterion is about
        # the paths being per-criterion and co-located, not about which
        # identifier names the directory, so it no longer says.
        dirs = expected_paths |> Enum.map(&Path.dirname/1) |> Enum.uniq()

        assert [dir] = dirs,
               "expected all three specs in one story directory, got: #{inspect(dirs)}"

        assert Path.dirname(dir) == "test/spex",
               "expected the story directory directly under test/spex, got `#{dir}`"

        assert length(Enum.uniq(expected_paths)) == 3,
               "expected three distinct paths, got: #{inspect(expected_paths)}"

        {:ok, context}
      end
    end
  end
end
