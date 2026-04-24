defmodule CodeMySpecSpex.Story560.Criterion5158Spex do
  @moduledoc """
  Story 560 — Persona Research
  Criterion 5158 — Cross-account link is rejected at link creation. Calling
  LinkPersonaToStory with a story_id that doesn't belong to the scope's
  active account returns an error response without creating a join row.
  """

  use CodeMySpecSpex.Case
  import_givens CodeMySpecSpex.SharedGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Personas.Tools.LinkPersonaToStory
  alias CodeMySpecSpex.Fixtures

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "PM attempts to link persona to a story in another account" do
    scenario "MCP response rejects with a cross-account error" do
      given_ :persona_exists

      given_ "a story exists in a different account", context do
        other_account =
          Fixtures.account_fixture(%{name: "Other account"})

        # Use the other account's scope to create the story there.
        other_scope = %CodeMySpec.Users.Scope{
          user: context.scope.user,
          user_id: context.scope.user.id,
          active_account: other_account,
          active_account_id: other_account.id
        }

        foreign_project =
          Fixtures.project_fixture(other_scope, %{name: "Other Project"})

        scope_with_project = %{
          other_scope
          | active_project: foreign_project,
            active_project_id: foreign_project.id
        }

        story =
          Fixtures.story_fixture(scope_with_project,
            title: "Foreign story",
            description: "This story belongs to a different account."
          )

        {:ok, Map.put(context, :foreign_story_id, story.id)}
      end

      when_ "the PM calls LinkPersonaToStory with the foreign story_id", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          LinkPersonaToStory.execute(
            %{persona_id: context.persona_id, story_id: context.foreign_story_id},
            frame
          )

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the MCP response names the cross-account rejection", context do
        body = response_text(context.response)

        assert body =~ ~r/cross-account|does not belong|account/i,
               "expected MCP response to reject the cross-account link, got #{inspect(context.response)}"

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
