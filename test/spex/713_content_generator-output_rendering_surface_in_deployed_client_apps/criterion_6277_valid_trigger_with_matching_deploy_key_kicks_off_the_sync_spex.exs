defmodule CodeMySpecSpex.Story713.Criterion6277Spex do
  @moduledoc """
  Story 713 — Content rendering surface in deployed client apps.
  Criterion 6277 — Valid trigger with matching deploy_key kicks off the sync.

  Rule: The client app exposes `POST /api/content/pull` accepting
  `Authorization: Bearer <deploy_key>` and a body containing the manifest URL.
  Requests without a valid `deploy_key` return 401; the pre-shared key is
  symmetric with the CLI's outbound trigger call (story 712).

  Surface:
    * HTTP `POST /api/content/pull` on the client (CodeMySpecWeb). A matching
      deploy key returns 202 and starts a sync job that fetches the manifest
      from the body URL (captured via the stubbed pull client). A wrong key
      returns 401 and starts nothing.
  """

  use CodeMySpecSpex.Case

  alias CodeMySpecSpex.Fixtures

  @endpoint CodeMySpecWeb.Endpoint

  setup :set_deploy_key
  setup :stub_pull

  @manifest_url "https://content.foo.com/manifest.json"

  spex "A valid deploy key accepts the trigger; a wrong key is rejected" do
    scenario "Valid trigger with matching deploy_key kicks off the sync" do
      given_ "the client is configured with a deploy key", context do
        # given: already true — `setup :set_deploy_key` puts the key the
        # trigger endpoint authorizes against into application config, and
        # restores it afterwards.
        {:ok, context}
      end

      when_ "a pull trigger arrives with the matching bearer key", context do
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer k-abc123")
          |> put_req_header("content-type", "application/json")
          |> post("/api/content/pull", %{"manifest_url" => @manifest_url})

        {:ok, Map.put(context, :conn, conn)}
      end

      then_ "the response is 202 and a manifest fetch is started", context do
        assert json_response(context.conn, 202)

        # The sync job runs async, so wait briefly for the fetch to start.
        assert_receive {:pull_fetch, @manifest_url},
                       1000,
                       "a 202 must start a sync job that fetches the manifest URL"

        {:ok, context}
      end
    end

    scenario "A wrong deploy_key returns 401 and starts nothing" do
      when_ "a pull trigger arrives with a wrong bearer key", context do
        conn =
          build_conn()
          |> put_req_header("authorization", "Bearer wrong-key")
          |> put_req_header("content-type", "application/json")
          |> post("/api/content/pull", %{"manifest_url" => @manifest_url})

        {:ok, Map.put(context, :conn, conn)}
      end

      then_ "the response is 401 and no fetch is started", context do
        assert json_response(context.conn, 401)

        refute_received {:pull_fetch, _url},
                        "a rejected trigger must not start a manifest fetch"

        {:ok, context}
      end
    end
  end

  defp set_deploy_key(_context) do
    previous = Application.get_env(:code_my_spec, :deploy_key)
    Application.put_env(:code_my_spec, :deploy_key, "k-abc123")
    on_exit(fn -> Application.put_env(:code_my_spec, :deploy_key, previous) end)
    :ok
  end

  defp stub_pull(_context), do: Fixtures.stub_content_pull(:no_content)
end
