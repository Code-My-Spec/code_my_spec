defmodule CodeMySpecSpex.Fakes.StorageWiringTest do
  @moduledoc """
  The storage fake driven through `Provisioning.Storage`, which goes via ExAws.

  Separate from the direct tests because the two answer different questions,
  and the first attempt at this could answer neither: it hung, five times, at
  ExUnit's 60s default. ExAws retries with backoff, so a fake answering in a
  shape it does not expect is indistinguishable from a slow network — the only
  symptom is time passing.

  The short timeout is the fix for that and stays deliberately. Five seconds
  turns "something is wrong somewhere" into a stacktrace naming
  `await_bucket/6`, which is how the actual cause was found: `ensure_bucket/3`
  polls with `head_bucket` — a fresh Hetzner bucket 404s for about a second —
  and the fake had no `HEAD` route, so every poll got the catch-all and was
  retried.

  Incomplete, not broken. Worth remembering when the next fake looks broken.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Provisioning.Storage
  alias CodeMySpecSpex.Fakes

  @moduletag timeout: 5_000

  setup do
    {:ok, agent} = Agent.start_link(&Fakes.Storage.new/0)
    previous = Application.get_env(:code_my_spec, CodeMySpec.Content.S3Client, [])

    # A `Req.Test` stub rather than a function plug, because the plug lives in
    # application env and application env is global. Two async tests each
    # writing their own function there fight, and the loser gets the other's
    # fake — or, when the winner wrote `{Req.Test, …}`, `cannot find mock/stub`
    # for a stub it never installed.
    #
    # The tuple is the same for everyone and the stub is per-process, so this
    # composes with `fake_providers/1` doing the same thing in the spex suite.
    Application.put_env(:code_my_spec, CodeMySpec.Content.S3Client,
      plug: {Req.Test, CodeMySpec.Content.S3Client}
    )

    Req.Test.stub(CodeMySpec.Content.S3Client, &Fakes.Storage.call(&1, agent))

    on_exit(fn -> Application.put_env(:code_my_spec, CodeMySpec.Content.S3Client, previous) end)

    %{credentials: [access_key_id: "fake-id", secret_access_key: "fake-secret", region: "fsn1"]}
  end

  test "listing buckets through ExAws reaches the fake", %{credentials: creds} do
    assert {:ok, _names} = Storage.list_buckets(creds)
  end

  test "ensure_bucket reaches the fake", %{credentials: creds} do
    assert {:ok, _} = Storage.ensure_bucket("sams-dumps", creds)
  end

  test "put_object reaches the fake", %{credentials: creds} do
    {:ok, _} = Storage.ensure_bucket("sams-dumps", creds)
    assert :ok = Storage.put_object("sams-dumps", "dumps/prod/one.sql.gz", "PGDMP", creds)
  end

  test "list_dumps reaches the fake", %{credentials: creds} do
    {:ok, _} = Storage.ensure_bucket("sams-dumps", creds)
    assert {:ok, _dumps} = Storage.list_dumps("sams-dumps", creds, prefix: "dumps/")
  end

  test "put_lifecycle reaches the fake", %{credentials: creds} do
    {:ok, _} = Storage.ensure_bucket("sams-dumps", creds)
    assert :ok = Storage.put_lifecycle("sams-dumps", 30, creds)
  end
end
