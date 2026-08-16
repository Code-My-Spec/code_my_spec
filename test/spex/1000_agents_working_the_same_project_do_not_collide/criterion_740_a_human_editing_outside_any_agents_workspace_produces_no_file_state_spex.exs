defmodule CodeMySpecSpex.Story1000.Criterion740Spex do
  @moduledoc """
  Story 1000 — Agents working the same project do not collide.
  Criterion 740 — A human editing outside any agent's workspace produces no file state.

  Rule: Only work in an agent's workspace is tracked.

  The boundary of what the project knows. A checkout nobody is serving is not a
  quiet agent — it is not an agent, and files edited in it are not the project's
  business. Recording them would mean the project's file state included work no
  agent could ever reconcile, and requirements moving because of edits nothing is
  watching.

  Surface: the hook endpoint, because the failure this guards against is a hook
  arriving for a working copy no harness serves. The honest answer is to record
  nothing, not to invent an agent to attribute it to.
  """

  use CodeMySpecSpex.Case

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Only a served working copy is tracked" do
    scenario "A human editing outside any agent's workspace produces no file state" do
      given_ "a working copy that no agent is serving", context do
        # Never joined the channel, so no id was ever issued for it. A real
        # directory on a real disk that the project has never heard of.
        {:ok, unserved} = Briefly.create(directory: true)

        {:ok, Map.put(context, :unserved, unserved)}
      end

      when_ "the operator edits files in it", context do
        # No header at all, because there is no id to send: nothing issued one
        # for this directory. Announcing the path instead is what the server used
        # to accept, and accepting it is how an edit in a directory no agent
        # serves got recorded against the project anyway.
        response =
          Phoenix.ConnTest.build_conn()
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post(~p"/api/hooks/post-tool-use", %{
            "session_id" => "spex-unserved",
            "tool_name" => "Edit",
            "tool_input" => %{"file_path" => Path.join(context.unserved, "lib/stray.ex")}
          })

        {:ok, Map.put(context, :hook_status, response.status)}
      end

      then_ "no files are recorded for the project", context do
        # The project's own file view is where a stray edit would surface. It must
        # not name a path from a directory no agent serves.
        {:ok, _files_live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        refute html =~ "stray.ex",
               "a file from a working copy no agent serves was recorded against the project. " <>
                 "Nothing can reconcile it: there is no agent to attribute it to and no " <>
                 "checkout the project can reach to re-read it."

        # Anchor: the page rendered at all, so the refute above means something.
        assert html =~ context.project.name

        {:ok, context}
      end

      then_ "no requirement changes state as a result", context do
        {:ok, _requirements_live, html} =
          live(context.conn, "/app/projects/#{context.project.id}/requirements")

        refute html =~ "stray.ex"
        assert html =~ context.project.name

        {:ok, context}
      end
    end
  end
end
