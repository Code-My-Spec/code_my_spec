defmodule CodeMySpec.BddRules do
  @moduledoc """
  The BddRules context — Three Amigos blue cards.

  Rules are first-class records produced during a Three Amigos session.
  Each Rule belongs to a Story and groups one or more scenarios (Criteria).
  Creating a Rule requires the story to have at least one persona linked
  via `persona_stories` — enforced at the context / repository boundary,
  not as a UI convention.

  Named `BddRules` to disambiguate from `CodeMySpec.Rules`, which is a
  separate, pre-existing context for coding-convention markdown rules
  consumed by agent task prompts. The domain artifact is still just
  "rule" — the namespacing prefix is purely a module-name disambiguator.

  Direct-DB implementation via `BddRulesRepository`. The
  `:bdd_rules_implementation` config key is kept as a swap point for test
  doubles.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CodeMySpec.AcceptanceCriteria,
      CodeMySpec.Accounts,
      CodeMySpec.Personas,
      CodeMySpec.Projects,
      CodeMySpec.Repo,
      CodeMySpec.Requirements,
      CodeMySpec.Stories,
      CodeMySpec.Users,
      CodeMySpec.Utils
    ],
    exports: :all

  alias CodeMySpec.BddRules.BddRulesRepository
  alias CodeMySpec.Requirements.GraphInputs
  alias CodeMySpec.Users.Scope

  defp impl do
    Application.get_env(:code_my_spec, :bdd_rules_implementation, BddRulesRepository)
  end

  @doc """
  Subscribes to scoped notifications about BDD rule changes.

  Broadcasts match the pattern:

    * {:bdd_rule_created, %Rule{}}
    * {:bdd_rule_updated, %Rule{}}
    * {:bdd_rule_deleted, %Rule{}}

  """
  def subscribe(%Scope{} = scope) do
    key = scope.active_account_id
    Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "user:#{key}:bdd_rules")
  end

  defp broadcast(%Scope{} = scope, message) do
    key = scope.active_account_id
    Phoenix.PubSub.broadcast(CodeMySpec.PubSub, "user:#{key}:bdd_rules", message)

    GraphInputs.announce(scope, "BddRules", GraphInputs.story_entities(message), :project_wide)
  end

  @doc """
  Creates a Rule on the given story. Rejects when the story has no
  linked personas (`{:error, :persona_linkage_required}`).
  """
  def create_rule(scope, story_id, attrs) do
    case impl().create_rule(scope, story_id, attrs) do
      {:ok, rule} = ok ->
        broadcast(scope, {:bdd_rule_created, rule})
        ok

      other ->
        other
    end
  end

  @doc """
  Lists every Rule on the given story, ordered by `inserted_at` ascending.
  """
  def list_rules_for_story(scope, story_id),
    do: impl().list_rules_for_story(scope, story_id)

  @doc "Lists every Rule in the given project."
  def list_rules_for_project(scope, project_id),
    do: impl().list_rules_for_project(scope, project_id)

  @doc "Fetches a single Rule by id within the active account scope."
  def get_rule(scope, id), do: impl().get_rule(scope, id)

  @doc "Updates a Rule's statement (PM-side edit). Broadcasts on success."
  def update_rule(scope, %CodeMySpec.BddRules.Rule{} = rule, attrs) do
    case impl().update_rule(scope, rule, attrs) do
      {:ok, updated} = ok ->
        broadcast(scope, {:bdd_rule_updated, updated})
        ok

      other ->
        other
    end
  end

  @doc "Deletes a Rule (PM-side admin action). Broadcasts on success."
  def delete_rule(scope, %CodeMySpec.BddRules.Rule{} = rule) do
    case impl().delete_rule(scope, rule) do
      {:ok, deleted} = ok ->
        broadcast(scope, {:bdd_rule_deleted, deleted})
        ok

      other ->
        other
    end
  end
end
