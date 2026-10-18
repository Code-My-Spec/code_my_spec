defmodule CodeMySpecSpex.Story682.Criterion5830Spex do
  @moduledoc """
  Story 682 — Architect Agent Surface
  Criterion 5830 — Architect reuses an existing component to satisfy a new
  story.

  When a story arrives whose acceptance criteria fit an existing component,
  the architect links the story to that component without creating a new
  one. The component count stays the same; only the link is added.

  Surface: `set_story_component` MCP tool plus `list_components` to confirm
  no new component was created.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary
  alias Anubis.Server.Frame
  alias CodeMySpecSpex.Fixtures
  alias CodeMySpecSpex.StoryHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The architect reuses an existing component to satisfy a new story", criterion: 367 do
    scenario "no new component is created when an existing one fits" do
      given_ "an existing component fits the new story", context do
        proposal = Fixtures.proposal_with_context("MyApp", "Accounts", "Accounts domain")

        {:ok, _result} =
          Fixtures.with_executed_proposal(context.scope, context.environment, proposal)

        {:ok, Map.put(context, :module_name, "MyApp.Accounts")}
      end

      given_ "a new story arrives without a component_id", context do
        story =
          StoryHelpers.create_story(context.scope,
            title: "Story — fits Accounts",
            description: "Story fits Accounts",
            acceptance_criteria: ["Story fits Accounts criterion"]
          )

        {:ok, Map.put(context, :story, story)}
      end

      given_ "we record the current component count", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "list_components",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        before_count = count_components_in_response(response)

        {:ok, Map.put(context, :before_count, before_count)}
      end

      when_ "the architect links the story to the existing component", context do
        frame = %Frame{
          assigns: %{
            current_scope: context.scope,
            remote_client_opts: [plug: stub_remote_plug(), token: "test-token"]
          }
        }

        params = %{
          story_number: context.story.number,
          module_name: context.module_name
        }

        response =
          ToolLibrary.run(
            "set_story_component",
            params,
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        {:ok, Map.put(context, :link_response, response)}
      end

      then_ "the link succeeds", context do
        assert match?({:ok, _}, context.link_response),
               "expected set_story_component to succeed, got: #{inspect(context.link_response)}"

        {:ok, context}
      end

      then_ "the component count is unchanged — no new component was created",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        response =
          ToolLibrary.run(
            "list_components",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        after_count = count_components_in_response(response)

        assert after_count == context.before_count,
               "expected component count to stay at #{context.before_count}, got #{after_count}"

        {:ok, context}
      end
    end
  end

  defp count_components_in_response(response) do
    response
    |> response_text()
    |> Jason.decode!()
    |> Map.get("components", [])
    |> length()
  end

  defp stub_remote_plug do
    fn conn ->
      body = Jason.encode!(%{data: []})

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end
  end
end
