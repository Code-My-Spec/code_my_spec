defmodule CodeMySpecSpex.Story1132.Criterion2351Spex do
  @moduledoc """
  Story 1132 -- A dev box gets its dev secrets from the server.
  Criterion 2351 -- Nothing on the network can ask for the key.

  Reads every route the harness's own local HTTP router
  (`CmsHarness.Web.Router`, the surface this criterion's own `When` names)
  actually answers -- the exhaustive list, not a guess at a few plausible
  paths, since "there is no endpoint that answers with it" is a claim
  about the whole router, not about whichever path a spec happened to try.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CodeMySpecSpex.Fixtures

  spex "The key is reachable through nothing the harness serves over HTTP", criterion: 2351 do
    scenario "anything asks for the key over HTTP, on localhost or otherwise" do
      given_ "'cloud-1''s harness holds the dev key", context do
        dev_key = Fixtures.unique_age_private_key!()
        _rig = app_instance_rig(sops_age_keys: [dev_key])
        eventually(fn -> assert Fixtures.harness_holding_key?(dev_key) end)
        {:ok, context}
      end

      when_ "every route the harness answers over HTTP is listed", context do
        {:ok, Map.put(context, :paths, Fixtures.harness_web_route_paths())}
      end

      then_ "there is no endpoint that answers with it", context do
        suspect =
          Enum.filter(context.paths, fn path ->
            down = String.downcase(path)
            String.contains?(down, "key") or String.contains?(down, "sops")
          end)

        assert suspect == [],
               "the harness's HTTP router answers on a path that could serve the sops key: " <>
                 inspect(suspect)

        {:ok, context}
      end
    end
  end
end
