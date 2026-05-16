defmodule CodeMySpec.McpServers.BddRules.Tools.UpdateScenario do
  @moduledoc """
  Updates an existing Scenario (green card) — the Given/When/Then body,
  title, and/or kind. Unlike `add_scenario` this never re-links to a
  different rule; use `delete_criterion` + `add_scenario` if the
  scenario belongs under a different Rule.

  Refuses to edit verified (locked) scenarios — once a criterion has
  been marked verified, the wording is part of the audit trail.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.McpServers.BddRules.BddRulesMapper
  alias CodeMySpec.McpServers.Validators

  schema do
    field :criterion_id, :string,
      required: true,
      doc: "Criterion ID of the scenario to update (from `get_story` or `get_story_gherkin`)."

    field :title, :string,
      doc: "New scenario title (one-line, in domain language). Omit to leave unchanged."

    field :body, :string,
      doc: "New Given/When/Then body (plain-text Gherkin). Omit to leave unchanged."

    field :kind, :string,
      doc: "New scenario kind — `happy_path` or `failure_path`. Omit to leave unchanged."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         criterion when not is_nil(criterion) <-
           AcceptanceCriteria.get_criterion(scope, get_param(params, :criterion_id)),
         :ok <- check_not_verified(criterion),
         {:ok, attrs} <- build_attrs(params),
         {:ok, updated} <- AcceptanceCriteria.update_criterion(scope, criterion, attrs) do
      {:reply, BddRulesMapper.scenario_updated_response(updated), frame}
    else
      nil ->
        {:reply, BddRulesMapper.error(:criterion_not_found), frame}

      {:error, :criterion_verified} ->
        {:reply, BddRulesMapper.error(:criterion_verified), frame}

      {:error, :invalid_kind} ->
        {:reply, BddRulesMapper.error(:invalid_kind), frame}

      {:error, :no_attrs} ->
        {:reply, BddRulesMapper.error(:no_attrs), frame}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:reply, BddRulesMapper.validation_error(changeset), frame}

      {:error, reason} ->
        {:reply, BddRulesMapper.error(reason), frame}
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
