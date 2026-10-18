defmodule CodeMySpec.BddRules.Tools.UpdateScenario do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.BddRules.Tools.Responses, as: BddRulesMapper
  alias CodeMySpec.Stories.AcceptanceCriteria

  @impl true
  def name, do: "update_scenario"

  @impl true
  def description do
    """
    Updates an existing Scenario (green card) — the Given/When/Then body,
    title, and/or kind. Unlike `add_scenario` this never re-links to a
    different rule; use `retire_criterion` + `add_scenario` if the
    scenario belongs under a different Rule.

    Refuses to edit verified (locked) scenarios — once a criterion has
    been marked verified, the wording is part of the audit trail.
    """
  end

  @impl true
  def params do
    %{
      title:
        {:meta, :string,
         [
           description:
             "New scenario title (one-line, in domain language). Omit to leave unchanged."
         ]},
      body:
        {:meta, :string,
         [
           description: "New Given/When/Then body (plain-text Gherkin). Omit to leave unchanged."
         ]},
      kind:
        {:meta, :string,
         [
           description:
             "New scenario kind — `happy_path` or `failure_path`. Omit to leave unchanged."
         ]},
      criterion_number:
        {:required,
         {:meta, :integer,
          [
            description:
              "Criterion number of the scenario to update (from `get_story` or `get_story_gherkin`)."
          ]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         criterion when not is_nil(criterion) <-
           AcceptanceCriteria.get_criterion_by_number(scope, get_param(params, :criterion_number)),
         :ok <- check_not_verified(criterion),
         {:ok, attrs} <- build_attrs(params),
         {:ok, updated} <- AcceptanceCriteria.update_criterion(scope, criterion, attrs) do
      BddRulesMapper.scenario_updated_response(updated)
    else
      nil ->
        BddRulesMapper.error(:criterion_not_found)

      {:error, :criterion_verified} ->
        BddRulesMapper.error(:criterion_verified)

      {:error, :invalid_kind} ->
        BddRulesMapper.error(:invalid_kind)

      {:error, :no_attrs} ->
        BddRulesMapper.error(:no_attrs)

      {:error, %Ecto.Changeset{} = changeset} ->
        BddRulesMapper.validation_error(changeset)

      {:error, reason} ->
        BddRulesMapper.error(reason)
    end
  end

  defp check_not_verified(%{verified: true}), do: {:error, :criterion_verified}
  defp check_not_verified(_), do: :ok

  defp build_attrs(params) do
    attrs =
      %{}
      |> maybe_put(:description, get_param(params, :title))
      |> maybe_put(:body, get_param(params, :body))
      |> maybe_put_kind(get_param(params, :kind))

    case attrs do
      {:error, _} = err -> err
      attrs when map_size(attrs) == 0 -> {:error, :no_attrs}
      attrs -> {:ok, attrs}
    end
  end

  defp maybe_put({:error, _} = err, _key, _value), do: err
  defp maybe_put(attrs, _key, nil), do: attrs
  defp maybe_put(attrs, key, value), do: Map.put(attrs, key, value)

  defp maybe_put_kind({:error, _} = err, _value), do: err
  defp maybe_put_kind(attrs, nil), do: attrs
  defp maybe_put_kind(attrs, "happy_path"), do: Map.put(attrs, :kind, :happy_path)
  defp maybe_put_kind(attrs, "failure_path"), do: Map.put(attrs, :kind, :failure_path)
  defp maybe_put_kind(_attrs, _other), do: {:error, :invalid_kind}

  defp get_param(params, key) when is_atom(key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end
end
