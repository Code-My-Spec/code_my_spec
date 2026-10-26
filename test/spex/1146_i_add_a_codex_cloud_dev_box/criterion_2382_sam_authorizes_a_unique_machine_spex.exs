defmodule CodeMySpecSpex.Story1146.Criterion2382Spex do
  @moduledoc "The UI issues unique box identities and the public device grant endpoint vends approval links. Packaged startup OAuth remains an install integration check."
  use CodeMySpecSpex.Case
  import CodeMySpecSpex.DevBoxHelpers

  setup :register_log_in_setup_account
  setup :setup_active_project

  spex "Sam authorizes a unique machine", criterion: 2382 do
    scenario "Two cloud boxes request their own authorization" do
      given_ "Sam adds two Codex Cloud boxes", context do
        {:ok, view, _} = open_dev_boxes(context.conn, context.project)
        add_dev_box(view, "codex-one", "codex_cloud")
        first = box_device_id(view, "codex-one")
        add_dev_box(view, "codex-two", "codex_cloud")
        second = box_device_id(view, "codex-two")

        {:ok,
         Map.merge(context, %{
           view: view,
           identities: [first, second]
         })}
      end

      when_ "each machine requests a device grant", context do
        grants =
          Enum.map(context.identities, fn identity ->
            client =
              build_conn()
              |> post("/oauth/register", %{
                client_name: "Codex box #{identity}",
                redirect_uris: [],
                grant_types: ["urn:ietf:params:oauth:grant-type:device_code", "refresh_token"]
              })
              |> json_response(201)

            build_conn()
            |> post("/oauth/device/code", %{client_id: client["client_id"], device_id: identity})
            |> json_response(200)
          end)

        {:ok, Map.put(context, :grants, grants)}
      end

      then_ "each has its own identity and approval code, without a script credential", context do
        [first, second] = context.identities
        refute first == second
        [one, two] = context.grants
        refute one["user_code"] == two["user_code"]

        Enum.each(context.grants, fn grant ->
          assert grant["verification_uri"] =~ "/oauth/device"
          assert grant["verification_uri_complete"] =~ grant["user_code"]
        end)

        refute has_element?(context.view, "[data-test='new-dev-box-token']")
        assert has_element?(context.view, "[data-test='setup-auth']")
        script = context.view |> element("[data-test='setup-script']") |> render()
        refute script =~ "cbt_"
        refute script =~ "CMS_DEPLOY_KEY"
        {:ok, context}
      end
    end
  end
end
