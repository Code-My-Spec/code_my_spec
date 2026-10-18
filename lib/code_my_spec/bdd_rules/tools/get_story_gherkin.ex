defmodule CodeMySpec.BddRules.Tools.GetStoryGherkin do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.BddRules.GherkinRenderer
  alias CodeMySpec.BddRules.Tools.Responses, as: BddRulesMapper
  alias CodeMySpec.Stories

  @impl true
  def name, do: "get_story_gherkin"

  @impl true
  def description do
    """
    Renders a story's Three Amigos artifacts as a plain-text Gherkin
    `.feature` document.

    The DB is the source of truth; this tool assembles the view on demand.
    Used by downstream consumers (SexySpex generation, the local web UI's
    feature preview, codegen) — none of which read a `.feature` file from
    disk.
    """
  end

  @impl true
  def params do
    %{
      story_number:
        {:required,
         {:meta, :integer, [description: "Story number (list_story_titles shows them)"]}}
    }
  end

  @impl true
  def call(params, context) do
    with {:ok, scope} <- CodeMySpec.Tools.project_scope(context),
         {:story, %Stories.Story{} = story} <-
           {:story, Stories.get_story_by_number(scope, get_param(params, :story_number))} do
      gherkin = GherkinRenderer.render(scope, story)

      {:ok, gherkin}
    else
      {:story, nil} ->
        BddRulesMapper.error(:story_not_found)

      {:error, reason} ->
        BddRulesMapper.error(reason)
    end
  end

  defp get_param(params, key) when is_atom(key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end
end
