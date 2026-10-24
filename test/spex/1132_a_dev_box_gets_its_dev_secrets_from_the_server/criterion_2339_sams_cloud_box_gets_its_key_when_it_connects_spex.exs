defmodule CodeMySpecSpex.Story1132.Criterion2339Spex do
  @moduledoc """
  Story 1132 -- A dev box gets its dev secrets from the server.
  Criterion 2339 -- Sam's cloud box gets its key when it connects.

  Driven through the real harness-side round trip: `app_instance_rig/1`
  (shared with story 1108's criteria) brings up a real
  `CmsHarness.Project.ChannelClient`, joined to a real fake server over a
  real websocket, exactly as `CmsHarness.Projects.ensure_started/1` does in
  production -- not a test-side stand-in for the box. `sops_age_keys:`
  configures the fake server's join reply, the one place this reaches the
  harness's real `install_age_keys/1` (`lib/cms_harness/project/channel_client.ex`).

  A unique key per run (not a shared literal): `CmsHarness.SopsKeyring` is
  one process shared by the whole spex suite (the global, once-per-run
  harness `app_instance_rig/1` boots), so checking for a fixed placeholder
  would still pass once any earlier scenario had ever installed it --
  this checks that *this* scenario's own key specifically arrived. A
  *real* age key (`Fixtures.unique_age_private_key!/0`), not a literal
  string shaped like one: a malformed one left sitting in that shared
  keyring poisons the whole identity blob for a later, real-decrypt
  scenario (criteria 2346/2350) -- confirmed, not theoretical.

  `app_instance_rig/1`'s own `await_connected/2` only waits for the *fake
  server's* join callback to fire, not for the real client's `handle_join/3`
  to finish running on the far side of the wire -- there is no synchronous
  signal for that, so this polls the keyring (a public read, not internal
  process state) for a bounded time instead of a flat sleep.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CodeMySpecSpex.Fixtures

  spex "The cloud box's harness receives its key over the channel, never to a file",
    criterion: 2339 do
    scenario "Sam's box 'cloud-1' signs in" do
      given_ "the project is encrypted to a dev-only age recipient", context do
        {:ok, Map.put(context, :dev_key, Fixtures.unique_age_private_key!())}
      end

      when_ "'cloud-1' signs in, its harness joining the project's channel", context do
        rig = app_instance_rig(sops_age_keys: [context.dev_key])
        {:ok, Map.put(context, :rig, rig)}
      end

      then_ "its harness receives the project's dev-only age key", context do
        assert context.rig.working_copy_id,
               "the box never finished joining, so nothing about receiving a key is provable"

        eventually(fn ->
          assert Fixtures.harness_holding_key?(context.dev_key),
                 "the key the fake server handed over on join never reached the harness"
        end)

        {:ok, context}
      end

      then_ "no key file exists anywhere on the box", context do
        # This dev machine's own real sops keyring files may already exist
        # for unrelated reasons; existence alone proves nothing about this
        # run. Only this scenario's own unique key landing in one would.
        candidates = [
          Path.expand("~/.config/sops/age/keys.txt"),
          Path.expand("~/Library/Application Support/sops/age/keys.txt")
        ]

        leaked =
          Enum.filter(candidates, &(Fixtures.spex_read_file_or_blank(&1) =~ context.dev_key))

        assert leaked == [],
               "this run's key was written to a sops keyring file on disk (#{inspect(leaked)}); " <>
                 "the key must live only in the harness's memory, never on disk"

        {:ok, context}
      end
    end
  end
end
