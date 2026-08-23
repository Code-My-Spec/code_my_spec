defmodule CodeMySpecSpex.Story682.Criterion5874Spex do
  @moduledoc """
  Story 682 — Architect Agent Surface
  Criterion 5874 — The architecture task prompt only names tools that
  are actually registered on `CodeMySpec.McpServers.LocalServer`.

  The prompt is the contract between the harness and the Claude agent
  doing the architecture work. If the prompt names a tool the agent
  can't reach (because it isn't registered on the local MCP server),
  the agent reads the resolution menu, tries the tool, gets a
  method-not-found error, and silently degrades — either to a
  workaround that bypasses the architecture surface entirely or to
  stopping with the work undone. That's the bug class market_my_spec
  hit: the prompt named `create_dependency` and `delete_component` but
  neither was registered on the local server.

  This story (682) is the agent-perspective companion to story 70
  (Architecture Design). Story 70 captures human-architect outcomes;
  story 682 captures agent-side mechanics — tool-surface registration,
  prompt-as-contract correctness, scope-resolution robustness.

  Surface: `start_task` for `architecture_designed` (routes to
  `ArchitectureDesign.command/2`) + reflection on `LocalServer`.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.GraphGivens

  alias Anubis.Server.Frame
  alias CodeMySpec.Environments
  alias CodeMySpec.McpServers.LocalServer
  alias CodeMySpec.McpServers.Tasks.Tools.StartTask

  # Snake-case tokens that legitimately appear in the prompt but are
  # NOT MCP tool names. Add to this list only with a comment explaining
  # what each token is — the goal is for new entries to be conscious
  # decisions, not silent escapes.
  @non_tool_tokens MapSet.new([
                     # Document type identifier consumed by the proposal validator.
                     "architecture_proposal",
                     # Legacy config key in `.code_my_spec/config.yml`. The
                     # config classifier was deleted (commit e1423b91);
                     # token may still appear in older prompt strings.
                     "infrastructure_paths",
                     # Type-classifier value written into a context's spec
                     # `## Type` section — when set to `infrastructure`,
                     # the orphan-context rule skips the component.
                     # Domain value, not a tool name.
                     "infrastructure",
                     # Component type values rendered in the orphan diagnostic
                     # section (e.g. "(type: `liveview`)") — these are domain
                     # values from `Components.Registry`, not tool names. List
                     # mirrors `CreateComponent`'s `:type` enum.
                     "context",
                     "coordination_context",
                     "live_context",
                     "schema",
                     "behaviour",
                     "json",
                     "liveview",
                     "liveview_component",
                     "controller",
                     "module"
                   ])

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Architecture prompt only references tools registered on LocalServer" do
    scenario "Every tool name the prompt mentions is reachable by the agent" do
      given_ :fully_satisfied_project

      and_ "an orphan context is synced into the project DB",
           context do
        :ok =
          Environments.write_file(
            context.environment,
            ".code_my_spec/spec/my_orphan_context.spec.md",
            """
            # MyOrphanContext

            ## Type

            context

            An orphan context — no story link, no dependency edge, not in infrastructure_paths.

            ## Dependencies

            - None
            """
          )

        :ok =
          Environments.write_file(
            context.environment,
            "lib/my_orphan_context.ex",
            """
            defmodule MyOrphanContext do
              @moduledoc false
            end
            """
          )

        {:ok, sync_live, _html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        sync_live
        |> element("button[phx-click='sync']")
        |> render_click()

        {:ok, context}
      end

      and_ "the agent has signalled session start", context do
        session_id = "spex-#{System.unique_integer([:positive])}"

        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_working_copy_id)
        |> Plug.Conn.put_req_header("content-type", "application/json")
        |> post("/api/hooks/session-start", %{"session_id" => session_id})
        |> Phoenix.ConnTest.json_response(200)

        {:ok, Map.put(context, :session_id, session_id)}
      end

      when_ "the architect calls start_task for architecture_designed",
            context do
        frame = %Frame{assigns: %{current_scope: context.scope}}

        {:reply, response, _frame} =
          StartTask.execute(
            %{
              requirement_name: "architecture_designed",
              entity_type: "project",
              entity_id: to_string(context.project.id),
              session_id: context.session_id
            },
            frame
          )

        {:ok, Map.put(context, :prompt, response_text(response))}
      end

      then_ "every backtick-quoted snake_case token in the prompt is either a registered tool or on the explicit non-tool list",
            context do
        registered = registered_tool_names()

        candidates =
          Regex.scan(~r/`([a-z][a-z0-9_]+)`/, context.prompt, capture: :all_but_first)
          |> List.flatten()
          |> MapSet.new()

        unknown =
          candidates
          |> Enum.reject(fn token ->
            MapSet.member?(registered, token) or
              MapSet.member?(@non_tool_tokens, token)
          end)
          |> Enum.sort()

        assert unknown == [],
               """
               The architecture prompt references these snake_case tokens that are neither
               registered as tools on LocalServer nor on the non-tool whitelist:

                 #{Enum.map_join(unknown, "\n  ", &"- `#{&1}`")}

               Either register the tool on LocalServer (lib/code_my_spec/mcp_servers/local_server.ex)
               or — if the token is intentionally not a tool (config key, document type, etc.) —
               add it to @non_tool_tokens in this spec with a comment explaining what it is.
               """

        {:ok, context}
      end

      and_ "the resolution menu names tools that exist", context do
        # Tighten the contract: these specific tools MUST appear in
        # the prompt's resolution menu AND be registered. Drift in
        # either direction (prompt drops the mention, or registration
        # disappears) breaks the agent's ability to resolve orphans.
        #
        # Dependency wiring is intentionally NOT a tool — the spec
        # files are the source of truth and ComponentSync re-derives
        # edges on save. The prompt must still describe that path
        # (asserted via the `dependency edge` regex in criterion 5873).
        registered = registered_tool_names()

        for tool <- ["set_story_component"] do
          assert tool in registered,
                 "expected `#{tool}` to be registered on LocalServer, but it is not"

          assert context.prompt =~ "`#{tool}`",
                 "expected prompt to mention `#{tool}` in backticks, got: #{context.prompt}"
        end

        {:ok, context}
      end
    end
  end

  defp registered_tool_names do
    LocalServer.__components__(:tool)
    |> Enum.map(& &1.name)
    |> MapSet.new()
  end
end
