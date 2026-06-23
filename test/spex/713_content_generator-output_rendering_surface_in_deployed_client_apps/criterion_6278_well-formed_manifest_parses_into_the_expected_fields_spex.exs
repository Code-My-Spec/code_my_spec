defmodule CodeMySpecSpex.Story713.Criterion6278Spex do
  @moduledoc """
  Story 713 — Content rendering surface in deployed client apps.
  Criterion 6278 — Well-formed manifest parses into the expected fields.

  Rule: On a valid pull trigger the client fetches `manifest.json` from the
  URL in the request body and parses fields `version`, `generated_at`,
  `content_blob_url`, `content_blob_hash`, `counts`. A malformed manifest
  (missing required fields, wrong version) aborts the sync without touching
  existing content.

  Surface:
    * HTTP `POST /api/content/pull` on the client. A well-formed manifest
      (all five fields) plus a hash-matching blob drives the sync to
      completion, so the blob's content becomes visible at `/blog/:slug` —
      proving the manifest parsed and the sync proceeded past parsing. A
      manifest missing a required field aborts and leaves content absent.

      The mid-pipeline "nothing changes yet" guarantee between parse and
      hash-verification is covered observably by the integrity (6279) and
      atomicity (6280) specs; here we assert the parse drives a successful
      sync for a complete manifest and an abort for an incomplete one.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpec.Content.PullClient

  @endpoint CodeMySpecWeb.Endpoint

  setup :set_deploy_key

  spex "A complete manifest parses and drives the sync; an incomplete one aborts" do
    scenario "Well-formed manifest parses into the expected fields" do
      given_ "a well-formed manifest and a hash-matching blob are served", context do
        blob = [content_row("welcome", "Welcome Post")]
        stub_pull(blob, manifest_overrides: %{})
        {:ok, context}
      end

      when_ "a valid pull trigger arrives", context do
        build_conn()
        |> put_req_header("authorization", "Bearer k-abc123")
        |> put_req_header("content-type", "application/json")
        |> post("/api/content/pull", %{"manifest_url" => "https://content.foo.com/manifest.json"})

        {:ok, context}
      end

      then_ "the parsed manifest drives the sync and the content becomes visible", context do
        eventually(fn ->
          conn = get(build_conn(), "/blog/welcome")
          assert html_response(conn, 200) =~ "Welcome Post"
        end)

        {:ok, context}
      end
    end

    scenario "A manifest missing a required field aborts without touching content" do
      given_ "a manifest missing content_blob_hash is served", context do
        # Distinct slug so this assertion is independent of the first
        # scenario's persisted content (scenarios share the test sandbox).
        blob = [content_row("never-lands", "Should Not Land")]
        stub_pull(blob, manifest_overrides: %{drop: "content_blob_hash"})
        {:ok, context}
      end

      when_ "a valid pull trigger arrives", context do
        build_conn()
        |> put_req_header("authorization", "Bearer k-abc123")
        |> put_req_header("content-type", "application/json")
        |> post("/api/content/pull", %{"manifest_url" => "https://content.foo.com/manifest.json"})

        {:ok, context}
      end

      then_ "no content is persisted from the malformed manifest", context do
        # Give any (incorrectly-proceeding) sync a chance to run, then assert
        # the content never landed.
        Process.sleep(200)
        conn = get(build_conn(), "/blog/never-lands")
        assert conn.status == 404, "a malformed manifest must abort without persisting content"
        {:ok, context}
      end
    end
  end

  # -- helpers (shared shape across 713 sync specs) --

  defp content_row(slug, title) do
    %{
      "slug" => slug,
      "title" => title,
      "content_type" => "blog",
      "processed_content" => "# #{title}\n\nBody.",
      "protected" => false,
      "publish_at" => "2020-01-01T00:00:00Z",
      "expires_at" => nil,
      "tags" => []
    }
  end

  defp stub_pull(blob_rows, opts) do
    Req.Test.set_req_test_to_shared(%{})
    Application.put_env(:code_my_spec, PullClient, plug: {Req.Test, PullClient})
    on_exit(fn -> Application.delete_env(:code_my_spec, PullClient) end)

    blob_json = Jason.encode!(blob_rows)
    hash = "sha256:" <> (:crypto.hash(:sha256, blob_json) |> Base.encode16(case: :lower))

    manifest =
      %{
        "version" => "1.0",
        "generated_at" => "2026-05-15T12:00:00Z",
        "content_blob_url" => "https://content.foo.com/content.json",
        "content_blob_hash" => hash,
        "counts" => %{"blog" => length(blob_rows)}
      }
      |> apply_manifest_overrides(Keyword.get(opts, :manifest_overrides, %{}))

    Req.Test.stub(PullClient, fn conn ->
      body =
        case conn.request_path do
          "/manifest.json" -> Jason.encode!(manifest)
          "/content.json" -> blob_json
          _ -> "{}"
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, body)
    end)

    :ok
  end

  defp apply_manifest_overrides(manifest, %{drop: key}), do: Map.delete(manifest, key)
  defp apply_manifest_overrides(manifest, overrides), do: Map.merge(manifest, overrides)

  defp set_deploy_key(_context) do
    previous = Application.get_env(:code_my_spec, :deploy_key)
    Application.put_env(:code_my_spec, :deploy_key, "k-abc123")
    on_exit(fn -> Application.put_env(:code_my_spec, :deploy_key, previous) end)
    :ok
  end

  defp eventually(fun, retries \\ 40)
  defp eventually(fun, 0), do: fun.()

  defp eventually(fun, n) do
    fun.()
  rescue
    ExUnit.AssertionError ->
      Process.sleep(25)
      eventually(fun, n - 1)
  end
end
