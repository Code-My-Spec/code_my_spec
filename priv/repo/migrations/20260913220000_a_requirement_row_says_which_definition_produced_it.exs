defmodule CodeMySpec.Repo.Migrations.ARequirementRowSaysWhichDefinitionProducedIt do
  @moduledoc """
  A requirement row could not say which definition produced it.

  Six names — `spec_file`, `spec_valid`, `test_file`, `test_spec_alignment`,
  `implementation_file`, `tests_passing` — exist twice. A parent template
  (`context`, `coordination_context`, `live_context`) defines each as a `:child`
  def carrying `orchestrated_by: :develop_context`, and the child component's
  own type template defines the same name as a `:self` def carrying
  `orchestrated_by: nil`.

  Computing instantiates the parent's template, so a child's `spec_file` is the
  orchestrated one. Reading looked the definition up by `(entity, name)` against
  the child's *own* type and got the other one — so `orchestrated_by` came back
  nil and an orchestrated wave rendered with no context header, which is what an
  agent reads to decide what to dispatch.

  Invisible while reads recomputed: a computed node carries the right
  definition, and every read computed.

  Two columns rather than a definition id, because the pair is what the lookup
  needs and neither half is a foreign key into anything that exists — the
  definitions are code, not rows.

  Nullable, and the null means "written before this migration". `Projection`
  falls back to inferring for those, and the next pass over each vantage
  rewrites them with the columns set, so the fallback drains rather than
  persisting.
  """

  use Ecto.Migration

  def change do
    alter table(:requirements) do
      # Whose template produced this node — the *parent* context's type for a
      # child node, the entity's own type otherwise.
      add :owner_component_type, :string

      # `:parent`, `:child` or `:self`. With the owner type it names exactly one
      # definition, which is the whole point: the name alone does not.
      add :node_scope, :string
    end
  end
end
