defmodule CodeMySpecSpex.Story127.Criterion5933Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 5933 — A File row whose path is no longer on disk is reaped
  by the next sync, even when the watcher missed the delete event.

  Covers Rule "Disk is the source of truth; the DB is a projection of it."
  This shares its observable contract with 5919 (deleted impl reaped) —
  both prove that the **full sync path** reconciles deletions independent
  of whether a watcher saw them, since the memfs/spec environment has
  no live watcher firing the delete event. Same surface, distinct
  framing: 5919 frames it as "engineer deleted then re-synced"; 5933
  frames it as "watcher was offline, full sync catches up."

  This spec drives the test-role deletion path to keep its assertions
  visually distinct from 5919.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @impl_path "lib/example_context.ex"
  @test_path "test/example_context_test.exs"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer sees offline-deleted files reaped on the next full sync" do
    scenario "test file deleted while watcher offline is reaped after the next sync" do
      given_ "the agent has written an impl + test pair and the engineer has synced",
             context do
        :ok = Environments.write_file(context.environment, @impl_path, impl_content())
        :ok = Environments.write_file(context.environment, @test_path, test_content())

        {:ok, files_live, _html} =
          live(context.conn, "/app/projects/#{context.project.name}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, context}
      end

      given_ "both files appear in the Files projection", context do
        {:ok, files_live, _html} =
          live(context.conn, "/app/projects/#{context.project.name}/files")

        assert has_element?(files_live, "[data-file-path=\"#{@impl_path}\"]")
        assert has_element?(files_live, "[data-file-path=\"#{@test_path}\"]")
        {:ok, context}
      end

      when_ "the test file vanishes from disk (watcher missed it) and the engineer re-syncs",
            context do
        :ok = Environments.delete_file(context.environment, @test_path)

        {:ok, files_live, _html} =
          live(context.conn, "/app/projects/#{context.project.name}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, Map.put(context, :files_live, files_live)}
      end

      then_ "the test file row is reaped while the impl row remains", context do
        refute has_element?(
                 context.files_live,
                 "[data-file-path=\"#{@test_path}\"]"
               )

        # Anchor: the impl row still appears, proving sync ran and only
        # the truly-missing path was reaped.
        assert has_element?(
                 context.files_live,
                 "[data-file-path=\"#{@impl_path}\"]"
               )

        {:ok, context}
      end
    end
  end

  defp impl_content do
    """
    defmodule ExampleContext do
      @moduledoc false
    end
    """
  end

  defp test_content do
    """
    defmodule ExampleContextTest do
      use ExUnit.Case, async: true
    end
    """
  end
end
