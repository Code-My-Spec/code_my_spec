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
  harness's real `install_age_keys/1` (`lib/cms_harness/project/channel_client.ex`),
  which is what decides whether anything lands on disk.

  `app_instance_rig/1`'s own `await_connected/2` only waits for the *fake
  server's* join callback to fire, not for the real client's `handle_join/3`
  to finish running on the far side of the wire -- there is no synchronous
  signal this spec is allowed to read for that (reaching into the channel
  process's own state is exactly what the spex boundary forbids). The
  short, deliberate wait below is a known, temporary stand-in for that
  missing signal, not a claim that the race is actually fine.

  Both `then_` steps read `CmsHarness.SopsKeyring.path/0`, pointed at an
  isolated tmp path (`Fixtures.isolated_sops_keyring_path!/0`) so the
  assertion is about this test's own run. That a file is, today, the only
  available proof that the harness received anything is exactly the
  problem this story exists to fix: once the key lives only in memory,
  "receives the key" will need a different proof (most plausibly something
  criteria 2346/2350 give an external way to observe), and this `then_`
  will need to change along with the implementation that makes it true.
  """

  use CodeMySpecSpex.Case

  import CmsHarnessTest.AppInstanceHelpers

  alias CodeMySpecSpex.Fixtures

  @dev_key "AGE-SECRET-KEY-1DEV"

  spex "The cloud box's harness receives its key over the channel, never to a file",
    criterion: 2339 do
    scenario "Sam's box 'cloud-1' signs in" do
      given_ "the project is encrypted to a dev-only age recipient", context do
        keyring_path = Fixtures.isolated_sops_keyring_path!()
        {:ok, Map.put(context, :keyring_path, keyring_path)}
      end

      when_ "'cloud-1' signs in, its harness joining the project's channel", context do
        rig = app_instance_rig(sops_age_keys: [@dev_key])
        Process.sleep(300)
        {:ok, Map.put(context, :rig, rig)}
      end

      then_ "its harness receives the project's dev-only age key", context do
        assert context.rig.working_copy_id,
               "the box never finished joining, so nothing about receiving a key is provable"

        assert Fixtures.spex_file_exists?(context.keyring_path) and
                 Fixtures.spex_read_file_or_blank(context.keyring_path) =~ @dev_key,
               "the key the fake server handed over on join never reached the harness at all"

        {:ok, context}
      end

      then_ "no key file exists anywhere on the box", context do
        refute Fixtures.spex_file_exists?(Fixtures.sops_keyring_path()),
               "a sops keyring file was written to disk; the key must live only in the " <>
                 "harness's memory, never on disk"

        {:ok, context}
      end
    end
  end
end
