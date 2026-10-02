defmodule CodeMySpecSpex.Story70.Criterion1646Spex do
  @moduledoc """
  Story 70 — Architecture Design
  Criterion 1646 — An unlinked released story still blocks architecture from counting as designed.

  Components as records, step 5 (3aeb66cf): `architecture_designed` reads the
  component records — authored, discovered or unmarked — instead of a proposal
  file and spec edits. Observed through `show_requirement`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  alias CodeMySpecSpex.ComponentHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "An unlinked released story still blocks architecture from counting as designed",
    criterion: 1646 do
    scenario "the architecture is authored but a released story has no component" do
      given_ "a project whose architecture is authored", context do
        ComponentHelpers.create(context.scope,
          name: "Accounts",
          module_name: "#{app(context)}.Accounts",
          type: "module"
        )

        {:ok, context}
      end

      when_ "a story is released with no component", context do
        story =
          CodeMySpecSpex.StoryHelpers.create_story(context.scope,
            title: "A feature",
            description: "Needs a feature",
            acceptance_criteria: ["It works"]
          )

        {:ok, Map.put(context, :story, story)}
      end

      then_ "architecture is blocked on it", context do
        assert architecture_designed(context) =~ "unlinked"
        assert architecture_designed(context) =~ "A feature"
        {:ok, context}
      end
    end
  end
end
