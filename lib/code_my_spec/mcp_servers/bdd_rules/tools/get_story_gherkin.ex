defmodule CodeMySpec.McpServers.BddRules.Tools.GetStoryGherkin do
  @moduledoc """
  Renders a story's Three Amigos artifacts as a plain-text Gherkin
  `.feature` document.

  The DB is the source of truth; this tool assembles the view on demand.
  Used by downstream consumers (SexySpex generation, the local web UI's
  feature preview, codegen) — none of which read a `.feature` file from
  disk.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.BddRules.GherkinRenderer
  alias CodeMySpec.McpServers.BddRules.BddRulesMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Stories
  alias Anubis.Server.Response

  schema do
    field :story_id, :integer,
      required: true,
      doc: "ID of the story whose Three Amigos artifacts should be rendered as Gherkin."
  end

  @impl true
  def execute(params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame),
         {:story, %Stories.Story{} = story} <-
           {:story, Stories.get_story(scope, get_param(params, :story_id))} do
      gherkin = GherkinRenderer.render(scope, story)

      {:reply, Response.tool() |> Response.text(gherkin), frame}
    else
      {:story, nil} ->
        {:reply, BddRulesMapper.error(:story_not_found), frame}

      {:error, reason} ->
        {:reply, BddRulesMapper.error(reason), frame}
    end
  end

  defp get_param(params, key) when is_atom(key) do
    Map.get(params, key) || Map.get(params, Atom.to_string(key))
  end
end
