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

  alias CodeMySpec.BddRules.Rule
  alias CodeMySpec.Personas
  alias CodeMySpec.Repo
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

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
        |> normalize()
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
          {:ok, Rule.t()} | {:error, :missing_active_account | :cross_account | Ecto.Changeset.t()}
  def update_rule(%Scope{active_account_id: account_id}, %Rule{} = rule, attrs)
      when not is_nil(account_id) do
    if rule.account_id == account_id do
      rule
      |> Rule.changeset(Map.delete(normalize(attrs), :account_id))
      |> Repo.update()
    else
      {:error, :cross_account}
    end
  end

  def update_rule(%Scope{}, _rule, _attrs), do: {:error, :missing_active_account}

  @spec delete_rule(Scope.t(), Rule.t()) ::
          {:ok, Rule.t()} | {:error, :missing_active_account | :cross_account}
  def delete_rule(%Scope{active_account_id: account_id}, %Rule{} = rule)
      when not is_nil(account_id) do
    if rule.account_id == account_id do
      Repo.delete(rule)
    else
      {:error, :cross_account}
    end
  end

  def delete_rule(%Scope{}, _rule), do: {:error, :missing_active_account}

  defp coerce_story_id(id) when is_integer(id), do: id
  defp coerce_story_id(id) when is_binary(id), do: String.to_integer(id)

  defp normalize(attrs) when is_map(attrs) do
    Map.new(attrs, fn
      {k, v} when is_atom(k) -> {k, v}
      {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
    end)
  rescue
    ArgumentError -> attrs
  end
end
