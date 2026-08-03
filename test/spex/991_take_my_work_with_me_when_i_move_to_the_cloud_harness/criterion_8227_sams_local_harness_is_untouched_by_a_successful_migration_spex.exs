defmodule CodeMySpecSpex.Story991.Criterion8227Spex do
  @moduledoc """
  Story 991 — Criterion 8227 — Sam's local harness is untouched by a successful
  migration.

  Covers Rule "Migration copies; the local harness keeps everything it had."

  Sam is upgrading, not committing. If the plan turns out to be wrong for him a
  month later, the work he did before paying has to still be on his own machine
  — so the migration reads and never writes locally. That is also why the local
  copy is not marked, flagged or locked afterwards: a "migrated" flag is a
  small thing that quietly turns a copy into a move.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Migrating leaves the local harness alone" do
    scenario "Sam's local harness is untouched by a successful migration" do
      given_ "Sam has authored a story locally", context do
        story = Fixtures.authored_story(context.scope, "Something Sam wrote")

        {:ok, context |> Map.put(:scope, Fixtures.paid(context.scope)) |> Map.put(:story, story)}
      end

      when_ "he migrates the project", context do
        assert Fixtures.migrate(context.scope, Fixtures.exported(context.scope)).status == 200

        {:ok, context}
      end

      then_ "the story is still on the local harness, unchanged", context do
        local = CodeMySpec.Stories.get_story(context.scope, context.story.id)

        assert local, "the local story must survive its own migration"
        assert local.title == "Something Sam wrote"

        {:ok, context}
      end

      and_ "nothing about it was marked or moved", context do
        local = CodeMySpec.Stories.get_story(context.scope, context.story.id)

        assert local.updated_at == context.story.updated_at,
               """
               Reading a project should not write to it. A touched timestamp
               means something stamped the record, and a stamp is how a copy
               quietly becomes a move.
               """

        {:ok, context}
      end
    end
  end
end
