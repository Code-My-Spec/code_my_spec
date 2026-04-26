defmodule CodeMySpecWeb.CriteriaJSON do
  alias CodeMySpec.AcceptanceCriteria.Criterion

  def index(%{criteria: criteria}) do
    %{data: Enum.map(criteria, &data/1)}
  end

  def show(%{criterion: criterion}) do
    %{data: data(criterion)}
  end

  defp data(%Criterion{} = criterion) do
    %{
      id: criterion.id,
      description: criterion.description,
      body: criterion.body,
      kind: criterion.kind,
      verified: criterion.verified,
      verified_at: criterion.verified_at,
      story_id: criterion.story_id,
      project_id: criterion.project_id,
      rule_id: criterion.rule_id,
      inserted_at: criterion.inserted_at,
      updated_at: criterion.updated_at
    }
  end
end
