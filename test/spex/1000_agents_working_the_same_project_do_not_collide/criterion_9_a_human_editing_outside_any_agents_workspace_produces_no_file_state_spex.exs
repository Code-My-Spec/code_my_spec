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

  spex "Only a served working copy is tracked", criterion: 9 do
    scenario "A human editing outside any agent's workspace produces no file state" do
      given_ "a working copy that no agent is serving", context do
        # Never joined the channel, so no id was ever issued for it. A real
        # directory on a real disk that the project has never heard of.
        unserved = CodeMySpec.TempFile.owned_dir("test")

        {:ok, Map.put(context, :unserved, unserved)}
      end

      when_ "the operator edits files in it", context do
        # A working copy id nothing on this machine has ever onboarded.
        # The harness router resolves purely by id (there is no directory
        # fallback, by design), so an unknown id is the found-nothing path —
        # not a path-based guess at whose workspace this is.
        response =
          CmsHarnessTest.LiveHarness.post_hook(
            "spex-unserved-#{System.unique_integer([:positive])}",
            "post-tool-use",
            %{
              "session_id" => "spex-unserved",
              "tool_name" => "Edit",
              "tool_input" => %{"file_path" => Path.join(context.unserved, "lib/stray.ex")}
            }
          )

        {:ok, Map.put(context, :hook_response, response)}
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
        {:ok, _graph_live, html} =
          live(
            context.conn,
            "/app/projects/#{context.project.id}/requirements/graph?preload=true"
          )

        refute html =~ "stray.ex"

        {:ok, context}
      end
    end
  end
end
