defmodule CodeMySpecSpex.Story127.Criterion5923Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 5923 — Watcher's single-path sync leaves mtime stale so the
  stop-hook catch-up re-validates.

  Covers the contract documented at `FileSync.sync_path` line 377:
  "Upsert metadata (role, owners, valid, fingerprint) but NOT mtime —
  leaves mtime stale so sync_changed still picks the file up during the
  stop hook pass."

  The user-visible proof: after the watcher's single-path sync fires
  on an edited file, the projection shows the NEW fingerprint but the
  ORIGINAL mtime — proving sync_path is willing to recompute content
  state in real time without claiming the file has been fully
  reconciled. (The catch-up half of the contract — full sync brings
  mtime forward — is its own user action and lives in its own
  scenario.)
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.Fixtures

  @impl_path "lib/stale_mtime_demo.ex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer sees sync_path advance fingerprint without bumping mtime" do
    scenario "single-path sync after edit leaves mtime stale; full sync catches it up" do
      given_ "the agent has written v1 and the engineer has full-synced", context do
        :ok = Environments.write_file(context.environment, @impl_path, content_v1())

        {:ok, files_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, context}
      end

      given_ "we capture the projected mtime for the v1 row", context do
        {:ok, _, html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        captured_mtime = extract_raw_mtime(html, @impl_path)
        assert is_binary(captured_mtime), "expected initial mtime to be rendered"
        {:ok, Map.put(context, :v1_mtime, captured_mtime)}
      end

      when_ "the agent edits to v2 and the watcher fires a single-path event", context do
        :ok = Environments.write_file(context.environment, @impl_path, content_v2())
        {:ok, _} = Fixtures.notify_file_changed(context.scope, @impl_path)
        {:ok, context}
      end

      then_ "the row shows v2's fingerprint but its mtime still equals the captured v1 mtime",
            context do
        {:ok, _, html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        post_sync_mtime = extract_raw_mtime(html, @impl_path)

        assert post_sync_mtime == context.v1_mtime,
               "expected sync_path to leave mtime stale; v1=#{context.v1_mtime} post=#{post_sync_mtime}"

        # Fingerprint moved forward — proves sync_path actually ran.
        assert html =~ "data-fingerprint=\"#{sha256(content_v2())}\""

        # Old fingerprint is gone.
        refute html =~ "data-fingerprint=\"#{sha256(content_v1())}\""

        {:ok, context}
      end

    end

    scenario "follow-up full sync brings the mtime forward, completing the catch-up" do
      given_ "the agent has written v1 and the engineer has full-synced", context do
        :ok = Environments.write_file(context.environment, @impl_path, content_v1())

        {:ok, files_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, context}
      end

      given_ "the agent has edited to v2 and the watcher fired a single-path event",
             context do
        {:ok, _, html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        captured_v1_mtime = extract_raw_mtime(html, @impl_path)
        assert is_binary(captured_v1_mtime), "expected v1 mtime to be rendered"

        :ok = Environments.write_file(context.environment, @impl_path, content_v2())
        {:ok, _} = Fixtures.notify_file_changed(context.scope, @impl_path)

        {:ok, Map.put(context, :v1_mtime, captured_v1_mtime)}
      end

      when_ "the engineer triggers a follow-up full sync", context do
        {:ok, files_live, _html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        files_live
        |> element("[data-test='sync-button']")
        |> render_click()

        {:ok, context}
      end

      then_ "the row's mtime is no longer the stale v1 value", context do
        {:ok, _, html} =
          live(context.conn, "/projects/#{context.project.name}/files")

        catch_up_mtime = extract_raw_mtime(html, @impl_path)

        assert is_binary(catch_up_mtime),
               "expected post-catch-up mtime to be rendered, got: #{inspect(catch_up_mtime)}"

        refute catch_up_mtime == context.v1_mtime,
               "expected full sync to update mtime past the stale value"

        {:ok, context}
      end
    end
  end

  defp extract_raw_mtime(html, path) do
    pattern =
      ~r/data-file-path="#{Regex.escape(path)}".*?data-mtime="([^"]+)"/s

    extract_match(Regex.run(pattern, html))
  end

  defp content_v1 do
    """
    defmodule StaleMtimeDemo do
      @moduledoc "v1"
    end
    """
  end

  defp content_v2 do
    """
    defmodule StaleMtimeDemo do
      @moduledoc "v2"
    end
    """
  end

  defp sha256(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end
  defp extract_match([_, value]), do: value
  defp extract_match(_), do: nil
end
