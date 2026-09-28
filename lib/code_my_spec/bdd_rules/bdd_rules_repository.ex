defmodule CodeMySpec.BddRules.BddRulesRepository do
  @moduledoc """
  Ecto queries for BDD rules. All queries scoped to the active
  account/project.

  `create_rule/3` enforces the persona-linkage gate: a rule cannot be
  created on a story that has zero personas linked via `persona_stories`.
  This is the structural enforcement of the Three Amigos rule "Persona
  linkage required" at the context boundary, before any rule lands in
  the DB.
  """

  import Ecto.Query, warn: false

  alias CodeMySpec.AcceptanceCriteria.Criterion
  alias CodeMySpec.BddRules.Rule
  alias CodeMySpec.Personas
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Utils

  @type attrs :: map()

  @spec create_rule(Scope.t(), integer() | String.t(), attrs()) ::
          {:ok, Rule.t()}
          | {:error,
             :missing_active_scope
             | :story_not_found
             | :cross_account
             | :persona_linkage_required
             | Ecto.Changeset.t()}
  def create_rule(
        %Scope{active_account_id: account_id, active_project_id: project_id} = scope,
        story_id,
        attrs
      )
      when not is_nil(account_id) and not is_nil(project_id) do
    story_id = coerce_story_id(story_id)

    with {:story, %Story{} = story} <- {:story, Repo.get(Story, story_id)},
         {:account, %Story{account_id: ^account_id, project_id: ^project_id}} <-
           {:account, story},
         {:linked, [_ | _]} <-
           {:linked, Personas.list_personas_for_story(scope, story.id)} do
      attrs =
        attrs
        |> Utils.normalize_keys()
        |> Map.put(:account_id, account_id)
        |> Map.put(:project_id, project_id)
        |> Map.put(:story_id, story.id)

      %Rule{}
      |> Rule.changeset(attrs)
      |> Repo.insert()
    else
      {:story, nil} -> {:error, :story_not_found}
      {:account, %Story{}} -> {:error, :cross_account}
      {:linked, []} -> {:error, :persona_linkage_required}
    end
  end

  def create_rule(%Scope{}, _story_id, _attrs), do: {:error, :missing_active_scope}

  @spec list_rules_for_story(Scope.t(), integer() | String.t()) :: [Rule.t()]
  def list_rules_for_story(%Scope{active_account_id: account_id}, story_id)
      when not is_nil(account_id) do
    story_id = coerce_story_id(story_id)

    Rule
    |> where([r], r.account_id == ^account_id and r.story_id == ^story_id)
    |> order_by([r], asc: r.inserted_at, asc: r.id)
    |> Repo.all()
  end

  def list_rules_for_story(%Scope{}, _story_id), do: []

  @spec list_rules_for_project(Scope.t(), integer() | String.t()) :: [Rule.t()]
  def list_rules_for_project(%Scope{active_account_id: account_id}, project_id)
      when not is_nil(account_id) do
    Rule
    |> where([r], r.account_id == ^account_id and r.project_id == ^project_id)
    |> order_by([r], asc: r.inserted_at, asc: r.id)
    |> Repo.all()
  end

  def list_rules_for_project(%Scope{}, _project_id), do: []

  @spec get_rule(Scope.t(), Ecto.UUID.t()) :: Rule.t() | nil
  def get_rule(%Scope{active_account_id: account_id}, id) when not is_nil(account_id) do
    Rule
    |> where([r], r.account_id == ^account_id and r.id == ^id)
    |> Repo.one()
  end

  def get_rule(%Scope{}, _id), do: nil

  @spec update_rule(Scope.t(), Rule.t(), map()) ::
          {:ok, Rule.t()}
          | {:error, :missing_active_account | :cross_account | Ecto.Changeset.t()}
  def update_rule(%Scope{active_account_id: account_id}, %Rule{} = rule, attrs)
      when not is_nil(account_id) do
    if rule.account_id == account_id do
      rule
      |> Rule.changeset(Map.delete(Utils.normalize_keys(attrs), :account_id))
      |> Repo.update()
    else
      {:error, :cross_account}
    end
  end

  def update_rule(%Scope{}, _rule, _attrs), do: {:error, :missing_active_account}

  @spec delete_rule(Scope.t(), Rule.t()) ::
          {:ok, Rule.t()}
          | {:error,
             :missing_active_account
             | :cross_account
             | {:criteria_verified_or_specced, [String.t()]}}
  def delete_rule(%Scope{active_account_id: account_id}, %Rule{} = rule)
      when not is_nil(account_id) do
    if rule.account_id == account_id do
      cascade_delete_rule(rule)
    else
      {:error, :cross_account}
    end
  end

  def delete_rule(%Scope{}, _rule), do: {:error, :missing_active_account}

  # Scenarios are Criteria linked via `rule_id`. The criteria→rule FK is
  # `on_delete: :nilify_all`, so a bare `Repo.delete(rule)` orphans them —
  # they survive with a dangling `rule_id` and keep inflating the story's
  # acceptance-criteria count. Delete them with the rule in one transaction
  # so the cascade the API advertises actually happens. DB-agnostic
  # (`delete_all` works on both SQLite and Postgres), so no FK migration.
  #
  # 146c01a6: refused when any linked criterion is `verified: true` or
  # already has a `spec_path` — the single-criterion delete path
  # (`AcceptanceCriteria.delete_criterion/2`'s `check_not_verified/1`) already
  # refuses the smaller version of this, and this cascade had no equivalent.
  # Measured on Broken Oaths: 23 verified criteria with real, passing spec
  # files deleted in one call, their descriptions immediately recreated under
  # new ids with `spec_path = nil` — the specs on disk, named for the deleted
  # ids, became unclaimable by anything. Recreating criteria under a rule
  # that already proved its scenarios is not what "PM-side cleanup of bogus
  # or superseded rules" (this tool's own doc) means; a rule that still has
  # verified work belongs to `update_rule`, not this.
  defp cascade_delete_rule(%Rule{id: rule_id} = rule) do
    case verified_or_specced(rule_id) do
      [] -> do_cascade_delete_rule(rule, rule_id)
      criteria -> {:error, {:criteria_verified_or_specced, Enum.map(criteria, & &1.description)}}
    end
  end

  defp do_cascade_delete_rule(rule, rule_id) do
    Repo.transaction(fn ->
      # Retired, not deleted: a criterion's number is never freed.
      Repo.update_all(from(c in Criterion, where: c.rule_id == ^rule_id),
        set: [retired_at: DateTime.utc_now(), rule_id: nil]
      )
      delete_or_rollback(rule)
    end)
  end

  defp delete_or_rollback(rule) do
    case Repo.delete(rule) do
      {:ok, deleted} -> deleted
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  defp verified_or_specced(rule_id) do
    Criterion
    |> where(
      [c],
      c.rule_id == ^rule_id and (c.verified == true or not is_nil(c.spec_path))
    )
    |> Repo.all()
  end

  defp coerce_story_id(id) when is_integer(id), do: id
  defp coerce_story_id(id) when is_binary(id), do: String.to_integer(id)
end
