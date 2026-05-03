defmodule CodeMySpecSpex.Story682.Criterion5831Spex do
  @moduledoc """
  Story 682 — Architect Agent Surface
  Criterion 5831 — Architect links a story to a component via the component
  linker tool.

  In patch mode the architect can link a single unlinked story to an existing
  component without rewriting the whole proposal. The `set_story_component`
  MCP tool takes a story ID and a component module name and assigns the
  component to the story.

  Surface: `set_story_component` MCP tool.
  """

  use CodeMySpecSpex.Case
  alias Anubis.Server.Frame
  alias CodeMySpec.McpServers.Stories.Tools.SetStoryComponent
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The architect links a story to a component via the component linker tool" do
    scenario "an unlinked story is linked to an existing component" do
      given_ "an existing component is available", context do
        proposal =
          Fixtures.proposal_with_context("MyApp", "Notifications", "Notifications domain context")

        {:ok, _result} =
          Fixtures.with_executed_proposal(context.scope, context.environment, proposal)

        {:ok, Map.put(context, :module_name, "MyApp.Notifications")}
      end

      given_ "an unlinked story exists", context do
        story =
          StoryHelpers.create_story(context.scope,
            title: "Story — needs notifications",
            description: "Needs notifications",
            acceptance_criteria: ["Notifications criterion"]
          )

        {:ok, Map.put(context, :story, story)}
      end

      when_ "the architect calls set_story_component with the story id and module name",
            context do
        frame = %Frame{
          assigns: %{
            current_scope: context.scope,
            remote_client_opts: [plug: stub_remote_plug(), token: "test-token"]
          }
        }

        params = %{
          story_id: Integer.to_string(context.story.id),
          module_name: context.module_name
        }

        {:reply, response, _frame} = SetStoryComponent.execute(params, frame)

        {:ok, Map.put(context, :link_response, response)}
      end

      then_ "the tool reports success", context do
        refute context.link_response.isError,
               "expected set_story_component to succeed, got: #{inspect(context.link_response)}"

        {:ok, context}
      end

      then_ "the response confirms the story is linked to a component", context do
        body = response_text(context.link_response)

        assert body =~ "Component assigned to story",
               "expected confirmation summary, got: #{inspect(body)}"

        assert body =~ context.story.title,
               "expected story title #{inspect(context.story.title)} in summary, got: #{inspect(body)}"

        {:ok, context}
      end
    end
  end

  defp stub_remote_plug do
    fn conn ->
      body = Jason.encode!(%{data: []})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end
  end

  defp response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: text} -> text
      %{"text" => text} -> text
      other -> inspect(other)
    end)
  end

  defp response_text(%{text: text}), do: text
  defp response_text(other), do: inspect(other)
end
