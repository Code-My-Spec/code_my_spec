defmodule CodeMySpecSpex.Story709.Criterion6214Spex do
  @moduledoc """
  Story 709 — Agent administers project issues
  Criterion 6214 — Agent runs the full issue lifecycle end-to-end:
  create → list → get → accept → resolve, observed through the
  Issues MCP tools.

  Surface: `create_issue`, `list_issues`, `get_issue`, `accept_issue`,
  `resolve_issue` MCP tools.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.ToolLibrary

  alias Anubis.Server.Frame

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Agent runs the full issue lifecycle through MCP tools", criterion: 448 do
    scenario "create surfaces an issue id" do
      when_ "the agent calls create_issue with scope app", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        params = %{
          title: "Loading spinner flickers on dashboard",
          severity: "medium",
          scope: "app",
          description: "Spinner re-mounts twice when navigating to the dashboard."
        }

        response =
          ToolLibrary.run(
            "create_issue",
            params,
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, response),
               "expected create_issue to succeed, got: #{inspect(response)}"

        {:ok, Map.put(context, :create_response, response)}
      end

      then_ "the response carries an issue id and the title", context do
        body = response_text(context.create_response)

        assert body =~ "Loading spinner flickers on dashboard",
               "expected title in response, got: #{inspect(body)}"

        assert body =~ ~r/ID:\s*[^\)\s]+/,
               "expected an issue id in the response, got: #{inspect(body)}"

        {:ok, context}
      end
    end

    scenario "list, get, accept, and resolve operate on the same issue" do
      given_ "an incoming issue exists", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        params = %{
          title: "Settings save button stuck disabled",
          severity: "high",
          scope: "app",
          description: "Save button stays disabled after editing the API key."
        }

        response =
          ToolLibrary.run(
            "create_issue",
            params,
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, response),
               "expected create_issue to succeed, got: #{inspect(response)}"

        issue_id = extract_issue_id(response)

        {:ok, Map.put(context, :issue_id, issue_id)}
      end

      when_ "the agent runs list → get → accept → resolve in order", context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        list_response =
          ToolLibrary.run(
            "list_issues",
            %{},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, list_response), "expected list_issues to succeed"

        get_response =
          ToolLibrary.run(
            "get_issue",
            %{issue_id: context.issue_id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, get_response), "expected get_issue to succeed"

        accept_response =
          ToolLibrary.run(
            "accept_issue",
            %{issue_id: context.issue_id, category: "bug"},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, accept_response), "expected accept_issue to succeed"

        resolve_response =
          ToolLibrary.run(
            "resolve_issue",
            %{
              issue_id: context.issue_id,
              resolution: "Re-enabled save button after key changes; covered by a test."
            },
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        assert match?({:ok, _}, resolve_response), "expected resolve_issue to succeed"

        {:ok,
         Map.merge(context, %{
           list_response: list_response,
           get_response: get_response,
           accept_response: accept_response,
           resolve_response: resolve_response
         })}
      end

      then_ "list_issues includes the issue by id and title", context do
        body = response_text(context.list_response)

        assert body =~ "Settings save button stuck disabled",
               "expected issue title in list output, got: #{inspect(body)}"

        assert body =~ context.issue_id,
               "expected issue id in list output, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "get_issue echoes the title and the id", context do
        body = response_text(context.get_response)

        assert body =~ "Settings save button stuck disabled",
               "expected title in get output, got: #{inspect(body)}"

        assert body =~ context.issue_id,
               "expected id in get output, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "accept_issue confirms acceptance with the bug disposition", context do
        body = response_text(context.accept_response)

        assert body =~ ~r/accepted/i,
               "expected acceptance confirmation, got: #{inspect(body)}"

        assert body =~ ~r/bug/i,
               "expected bug category in response, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "resolve_issue confirms resolution and surfaces the resolution text", context do
        body = response_text(context.resolve_response)

        assert body =~ ~r/resolved/i,
               "expected resolution confirmation, got: #{inspect(body)}"

        {:ok, context}
      end

      then_ "get_issue after resolution reflects the resolved status and resolution note",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        final =
          ToolLibrary.run(
            "get_issue",
            %{issue_id: context.issue_id},
            Map.put(frame.assigns, :scope, frame.assigns[:current_scope])
          )

        body = response_text(final)

        assert body =~ ~r/resolved/i,
               "expected final status resolved, got: #{inspect(body)}"

        assert body =~ "Re-enabled save button",
               "expected resolution note recorded, got: #{inspect(body)}"

        {:ok, context}
      end
    end
  end

  defp extract_issue_id(response) do
    [_, id] = Regex.run(~r/\(ID:\s*([^\)\s]+)\)/, response_text(response))
    id
  end
end
