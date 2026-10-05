defmodule CodeMySpecSpex.Story127.Criterion5921Spex do
  @moduledoc """
  Story 127 — Filesystem-to-DB Projection
  Criterion 5921 — Incremental sync processes only files whose mtime is
  newer than the DB record.

  Covers the contract of `FileSync.sync_changed/2`: on the stop hook's
  freestyle path, the validator runs `sync_changed` which uses an mtime
  pre-filter so unchanged files aren't re-stat'd or re-validated.

  Drives the real public surface: POST `/api/hooks/stop` with no
  session_id triggers `Validation.validate`, which calls `sync_changed`
  against the scope. A stop starts no analysis, so the pipeline completes
  without blocking and the post-hook projection state can be observed
  directly.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Environments
  alias CodeMySpecSpex.HarnessHooks

  @impl_a "lib/alpha.ex"
  @impl_b "lib/bravo.ex"

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Engineer sees only modified files refreshed on the freestyle stop hook", criterion: 78 do
    scenario "edited file advances; unchanged sibling's projection row is untouched" do
      given_ "the agent has written two impl files and the engineer has full-synced",
             context do
        :ok = Environments.write_file(context.environment, @impl_a, impl_a_v1())
        :ok = Environments.write_file(context.environment, @impl_b, impl_b())

        # Establish the live harness here, before anything snapshots a mtime.
        # Joining already does the full sync this needs: the harness's own
        # rescan-on-join reports every file at the real, whole-second mtime
        # the OS gives it. Clicking the files page's own sync button on top of
        # that would resync through the fixture's in-memory environment
        # instead of the harness's real checkout, restamping bravo with a
        # sub-second `DateTime.utc_now()` that the next real rescan would then
        # have to "correct" back to whole seconds — which is what this
        # criterion is asserting never happens.
        context = HarnessHooks.ensure_live_harness(context)

        {:ok, context}
      end

      given_ "we snapshot bravo's mtime so we can prove it stays untouched",
             context do
        {:ok, _, html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        bravo_mtime = extract_raw_mtime(html, @impl_b)
        alpha_v1_mtime = extract_raw_mtime(html, @impl_a)

        assert is_binary(bravo_mtime)
        assert is_binary(alpha_v1_mtime)

        {:ok, Map.merge(context, %{bravo_mtime: bravo_mtime, alpha_v1_mtime: alpha_v1_mtime})}
      end

      when_ "the agent edits alpha and the stop hook fires (freestyle, no session)",
            context do
        # mtime resolves to the whole second everywhere in this system
        # (environments_behaviour.ex:83); without a gap, this edit and the
        # baseline above can land in the same second and look unchanged.
        Process.sleep(1_000)
        :ok = Environments.write_file(context.environment, @impl_a, impl_a_v2())
        HarnessHooks.write_file(context, @impl_a, impl_a_v2())

        # A stop starts no analysis, so there is nothing to cassette.
        response = post_hook(context, "/api/hooks/stop", %{})

        {:ok, Map.put(context, :response, response)}
      end

      then_ "the hook allowed and alpha's projection advanced", context do
        assert context.response == %{},
               "freestyle clean run should allow, got: #{inspect(context.response)}"

        {:ok, _, html} =
          live(context.conn, "/app/projects/#{context.project.id}/files")

        alpha_post_mtime = extract_raw_mtime(html, @impl_a)

        # Alpha's fingerprint moved to v2 — sync_changed picked it up.
        assert html =~ "data-fingerprint=\"#{sha256(impl_a_v2())}\""

        # Alpha's mtime advanced past the original — sync_changed did
        # a full upsert (not the sync_path stale-mtime path).
        refute alpha_post_mtime == context.alpha_v1_mtime,
               "expected sync_changed to bump alpha's mtime; before=#{context.alpha_v1_mtime} after=#{alpha_post_mtime}"

        {:ok, Map.put(context, :html, html)}
      end

      and_ "bravo's projection row was not touched", context do
        bravo_post_mtime = extract_raw_mtime(context.html, @impl_b)

        assert bravo_post_mtime == context.bravo_mtime,
               "expected sync_changed to skip bravo (unchanged mtime); before=#{context.bravo_mtime} after=#{bravo_post_mtime}"

        # Anchor: bravo's fingerprint is still its original value.
        assert context.html =~ "data-fingerprint=\"#{sha256(impl_b())}\""

        {:ok, context}
      end
    end
  end

  defp extract_raw_mtime(html, path) do
    pattern =
      ~r/data-file-path="#{Regex.escape(path)}".*?data-mtime="([^"]+)"/s

    extract_match(Regex.run(pattern, html))
  end

  defp impl_a_v1 do
    """
    defmodule Alpha do
      @moduledoc "v1"
    end
    """
  end

  defp impl_a_v2 do
    """
    defmodule Alpha do
      @moduledoc "v2"
    end
    """
  end

  defp impl_b do
    """
    defmodule Bravo do
      @moduledoc false
    end
    """
  end

  defp sha256(content) do
    :crypto.hash(:sha256, content) |> Base.encode16(case: :lower)
  end

  defp extract_match([_, value]), do: value
  defp extract_match(_), do: nil
end
