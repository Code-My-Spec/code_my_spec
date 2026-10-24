defmodule CodeMySpecSpex.Story1132.Criterion2345Spex do
  @moduledoc """
  Story 1132 -- A dev box gets its dev secrets from the server.
  Criterion 2345 -- Sam revokes a box and it gets no key.

  There is no verb named "revoke" yet specific to a dev box's own token --
  only "Destroy" (`data-test="destroy-device"` on the Dev boxes page,
  `CodeMySpecWeb.DeviceLive.Index`), which removes the device outright.
  That is the real action this criterion's "revoked" maps onto: once the
  device row is gone, `Plugs.DeployKeyOrOAuth` resolves no `box_device` for
  its token and `DeviceController.create/2` never runs, so the harness
  never reaches a working-copy join where a key could be handed over at
  all.
  """

  use CodeMySpecSpex.Case

  import CodeMySpecSpex.DevBoxHelpers

  alias Ecto.Adapters.SQL.Sandbox

  @endpoint CodeMySpecWeb.Endpoint

  setup :register_log_in_setup_account
  setup :setup_active_project

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})
    :ok
  end

  spex "A revoked box is refused and never reaches a key", criterion: 2345 do
    scenario "Sam revoked 'cloud-1'" do
      given_ "Sam added 'cloud-1' and it signed in once", context do
        {:ok, live, _html} = open_dev_boxes(context.conn, context.project)
        add_dev_box(live, "cloud-1", "claude_code_cloud")
        token = shown_token(live)
        device_id = box_device_id(live, "cloud-1")

        assert %{"device_id" => _id} = sign_in_with(token),
               "the box could not even sign in before being revoked, so revoking it proves " <>
                 "nothing"

        {:ok, Map.merge(context, %{live: live, token: token, device_id: device_id})}
      end

      when_ "Sam revokes 'cloud-1'", context do
        context.live
        |> element(
          "[data-test='device'][data-device-id='#{context.device_id}'] " <>
            "[data-test='destroy-device']"
        )
        |> render_click()

        {:ok, context}
      end

      then_ "its harness is refused and receives no key", context do
        conn =
          build_conn()
          |> Plug.Conn.put_req_header("authorization", "Bearer " <> context.token)
          |> Plug.Conn.put_req_header("content-type", "application/json")
          |> post("/api/devices", %{"hostname" => "a-harness", "kind" => "cloud"})

        refute conn.status in 200..299,
               "a revoked box's token was still accepted (status #{conn.status})"

        refute response(conn, conn.status) =~ "AGE-SECRET-KEY-",
               "the refusal carried something that looks like a key"

        {:ok, context}
      end
    end
  end
end
