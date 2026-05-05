defmodule CodeMySpecSpex.Story127.Criterion5937Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 5937 — Test file misaligned with its spec is marked invalid
  with the alignment errors captured.

  Covers Rule "Validity is determined per file role" — cross-file
  alignment failure for the `:test` role. A test file that doesn't
  cover an assertion declared in its component spec's `## Test
  Assertions` section flips validity to invalid in the projection.

  Sync ordering note: FileSync (which validates per-role) runs before
  ComponentSync (which creates Component rows). So a test file written
  alongside its first-time spec can't be alignment-checked on the same
  sync — there's no component to resolve to yet. The given here syncs
  twice: first to materialize the component, then writes the misaligned
  test, then the engineer-triggered sync runs alignment.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments

  @spec_path ".code_my_spec/spec/aligned_context.spec.md"
  @impl_path "lib/aligned_context.ex"
  @test_path "test/aligned_context_test.exs"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer sees misaligned test files flagged invalid in the projection" do
    scenario "test file without the spec's required assertion is marked invalid" do
      given_ "the agent has written a context spec with Test Assertions and an impl, and the project has been synced once",
             context do
        :ok = Environments.write_file(context.environment, @spec_path, spec_with_assertions())
        :ok = Environments.write_file(context.environment, @impl_path, impl_content())

        {:ok, files_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, context}
      end

      given_ "the agent has written a test that does not implement the spec's assertions",
             context do
        :ok = Environments.write_file(context.environment, @test_path, misaligned_test())
        {:ok, context}
      end

      when_ "the engineer triggers a sync from the Files page", context do
        {:ok, files_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, Map.put(context, :files_live, files_live)}
      end

      then_ "the test file row shows the invalid badge", context do
        assert has_element?(
                 context.files_live,
                 "[data-file-path=\"#{@test_path}\"] [data-validity='invalid']"
               )

        {:ok, context}
      end
    end
  end

  defp spec_with_assertions do
    """
    # AlignedContext

    ## Type

    context

    A context with explicit Test Assertions for spec-alignment checks.

    ## Functions

    ### noop/0

    Returns `:ok`.

    ## Test Assertions

    - returns ok when called

    ## Dependencies

    - None

    ## Components

    ### AlignedContext.Inner

    Placeholder.
    """
  end

  defp impl_content do
    """
    defmodule AlignedContext do
      @moduledoc false
    end
    """
  end

  defp misaligned_test do
    """
    defmodule AlignedContextTest do
      use ExUnit.Case

      test "totally unrelated thing" do
        assert 1 + 1 == 2
      end
    end
    """
  end
end
