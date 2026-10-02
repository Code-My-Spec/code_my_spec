defmodule CodeMySpecSpex.Story127.Criterion1624Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 1624 — A component an agent created survives a full sync even though no file names it.

  A full sync pruned every component no file named — which is what an
  authored component is before its code exists (3aeb66cf).
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.ComponentGraphHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A component an agent created survives a full sync even though no file names it",
    criterion: 1624 do
    scenario "designed ahead of its code" do
      # A sync with no files at all prunes nothing — it will not delete on an
      # empty picture — so the project needs a real spec for this to test
      # anything.
      given_ "a project whose other context has a spec", context do
        spec!(context, "#{app(context)}.Web")
        sync!(context)
        {:ok, context}
      end

      given_ "an agent creates a component no file names", context do
        CodeMySpecSpex.ComponentHelpers.create(context.scope,
          name: "Billing",
          module_name: "#{app(context)}.Billing",
          type: "context"
        )

        {:ok, context}
      end

      when_ "a full sync runs", context do
        sync!(context)
        {:ok, context}
      end

      then_ "the component is still there", context do
        assert listed(context) =~ "#{app(context)}.Billing"
        {:ok, context}
      end
    end
  end
end
