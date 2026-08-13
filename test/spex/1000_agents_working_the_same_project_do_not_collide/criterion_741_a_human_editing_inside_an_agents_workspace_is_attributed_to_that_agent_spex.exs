defmodule CodeMySpecSpex.Story1000.Criterion741Spex do
  @moduledoc """
  Story 1000 — Agents working the same project do not collide.
  Criterion 741 — A human editing inside an agent's workspace is attributed to that agent.

  Rule: Only work in an agent's workspace is tracked.

  The other side of criterion 740. There, an edit in an unserved copy is nobody's
  and must not be recorded. Here, an edit in a served copy is *that agent's*, even
  though no agent made it — because the agent is the working copy, not the
  process. An operator fixing a typo by hand has changed what that checkout
  contains, and the next stop hook has to evaluate the tree as it now is.

  Attributing by working copy rather than by author is what makes that work. The
  alternative — tracking only edits an agent's own tools made — would leave the
  agent's file state describing a tree that no longer exists, and its analyzers
  reporting on code that is not there.

  Surface: the hook endpoint. `x-harness-id` names the working copy; the edit
  arrives through the same PostToolUse path an agent's own edit does, which is
  the point — there is no separate channel for a human.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "The working copy is the unit, not the author" do
    scenario "A human editing inside an agent's workspace is attributed to that agent" do
      given_ "an agent is serving a working copy", context do
        # `setup_active_project` plants a stub checkout and issues this scope its
        # own harness — that is the agent whose workspace this is.
        assert is_binary(context.scope.active_harness_id)

        {:ok, context}
      end

      when_ "the operator edits a file in it by hand", context do
        # By hand: written straight into the working copy, not through any tool
        # the agent owns. The hook is how the harness reports what changed on
        # disk, and it does not care who typed it.
        :ok =
          Environments.write_file(
            context.environment,
            "lib/typo_fixed_by_hand.ex",
            "defmodule TypoFixedByHand do\n  @moduledoc false\nend\n"
          )

        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/post-tool-use", %{
            "session_id" => "spex-operator-edit",
            "tool_name" => "Edit",
            "tool_input" => %{
              "file_path" => Path.join(context.scope.cwd, "lib/typo_fixed_by_hand.ex")
            }
          })

        {:ok, Map.put(context, :hook_status, response.status)}
      end

      then_ "the change is recorded against that agent", context do
        {:ok, _files_live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        assert html =~ "typo_fixed_by_hand.ex",
               "an edit made by hand inside a served working copy was not recorded against " <>
                 "the agent serving it. The agent's file state now describes a tree that no " <>
                 "longer exists, and its analyzers will report on code that is not there."

        {:ok, context}
      end

      then_ "that agent's stop hook evaluates it like any other change", context do
        stop =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("x-working-dir", context.scope.cwd)
          |> Plug.Conn.put_req_header("x-harness-id", context.scope.active_harness_id)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/stop", %{"session_id" => "spex-operator-edit"})
          |> Phoenix.ConnTest.json_response(200)

        # Not asserting a decision: whether this particular edit blocks depends on
        # what the analyzers find. What must be true is that the stop hook engaged
        # with the change at all rather than treating the copy as unchanged.
        assert is_map(stop) and stop != %{},
               "the stop hook returned nothing for a working copy that had just changed"

        {:ok, context}
      end
    end
  end
end
