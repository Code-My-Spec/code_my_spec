defmodule CodeMySpecSpex.Story560.Criterion5157Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5157 — Linking two personas to one story creates two join rows.
  Observable: two successive LinkPersonaToStory calls both return successful
  link confirmations referencing the same story_id with different persona_ids.
  """

  use CodeMySpecSpex.Case
  import_givens CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Personas.Tools.CreatePersona
  alias CodeMySpec.McpServers.Personas.Tools.LinkPersonaToStory
  alias CodeMySpec.Personas
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "two personas linked to one story" do
    scenario "both MCP link calls confirm with the same story_id" do
      given_ :persona_exists

      given_ "a second persona exists", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, _resp, _frame} =
          CreatePersona.execute(
            %{slug: "agency_pm", name: "Agency PM", headline: "Agency PM"},
            frame
          )

        second = Personas.get_persona_by_slug(context.scope, "agency_pm")

        {:ok, Map.put(context, :second_persona_id, second.id)}
      end

      given_ "a target story exists", context do
        story =
          Fixtures.story_fixture(context.scope,
            title: "Target story",
            description: "Two personas will link to this"
          )

        {:ok, Map.put(context, :target_story, story)}
      end

      when_ "both personas are linked via MCP", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, r1, _} =
          LinkPersonaToStory.execute(
            %{persona_id: context.persona_id, story_id: context.target_story.id},
            frame
          )

        {:reply, r2, _} =
          LinkPersonaToStory.execute(
            %{persona_id: context.second_persona_id, story_id: context.target_story.id},
            frame
          )

        {:ok,
         context
         |> Map.put(:first_response, r1)
         |> Map.put(:second_response, r2)}
      end

      then_ "both MCP responses confirm links against the same story_id", context do
        first_body = response_text(context.first_response)
        second_body = response_text(context.second_response)

        assert first_body =~ "linked"
        assert second_body =~ "linked"

        story_id = to_string(context.target_story.id)
        assert first_body =~ story_id
        assert second_body =~ story_id

        assert first_body =~ to_string(context.persona_id)
        assert second_body =~ to_string(context.second_persona_id)

        :ok
      end
    end
  end

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: t} -> t
      %{"text" => t} -> t
      o -> inspect(o)
    end)
  end

  defp response_text(other), do: inspect(other)
end
