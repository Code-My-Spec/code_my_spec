defmodule CodeMySpecSpex.Story1016.Criterion1760Spex do
  @moduledoc """
  Story 1016 — Stories are assigned to a working copy.
  Criterion 1760 — A coding or QA agent bound to a story is offered, and held
  back by, only that story's subgraph: its surface component and the surface's
  descendants, everything they depend on, and the direct children of the
  contexts among those dependencies — never another story's requirements nor a
  dependency context's grandchildren.

  d1a69b4e: expanding every dependency's descendants handed story 1083's coder
  568 of 1,319 components, phantom modules of retired stories among them.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.StorySliceHelpers, as: Slice

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "A bound coder works its story's subgraph and nothing beyond it", criterion: 1760 do
    scenario "the story depends on a context with an unbuilt child and an unbuilt grandchild" do
      given_ "Reservations depends on the Catalog context, whose child and grandchild are missing",
             context do
        context =
          context
          |> Slice.base()
          |> Slice.topology([
            {"Reservations", :context, ["Catalog"]},
            {"Catalog", :context, []},
            {"Catalog.Item", :schema, []},
            {"Catalog.Pricing", :module, []},
            {"Catalog.Pricing.Rule", :schema, []}
          ])
          |> Slice.missing("Catalog.Item")
          |> Slice.missing("Catalog.Pricing.Rule")

        {:ok, Map.put(context, :coder, Enum.find(context.team, &(&1.role == :coding)))}
      end

      when_ "the story's bound coding agent asks what to do next", context do
        {:ok, Map.put(context, :text, Slice.next(context, %{agent_id: context.coder.id}))}
      end

      then_ "it is offered the dependency context's child", context do
        Slice.assert_active(context.text, context, "ready")

        assert Slice.offered?(context.text, Slice.component(context, "Catalog.Item").id),
               context.text

        {:ok, context}
      end

      then_ "and not the dependency context's grandchild", context do
        refute Slice.offered?(context.text, Slice.component(context, "Catalog.Pricing.Rule").id),
               "a grandchild of a dependency context was offered as the bound story's work:\n" <>
                 context.text

        {:ok, context}
      end
    end
  end
end
