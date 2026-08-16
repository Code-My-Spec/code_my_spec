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

    %{
      agent: agent,
      credentials: [access_key_id: "fake-id", secret_access_key: "fake-secret", region: "fsn1"]
    }
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

  # Setting a lifecycle rule is `PUT /<bucket>/?lifecycle` — the create-bucket
  # request plus a query — so the create clause, which matched any query, was
  # swallowing it. The rule was never stored, and criterion 8016 read a bucket
  # with no retention on it while the step that set one reported success.
  test "a lifecycle rule survives being set", %{credentials: creds} do
    {:ok, _} = Storage.ensure_bucket("sams-dumps", creds)
    :ok = Storage.put_lifecycle("sams-dumps", 30, creds)

    assert {:ok, days} = Storage.get_lifecycle("sams-dumps", creds)
    assert days == 30
  end

  # Every reader of a listing is asking a question about time — is last night's
  # dump there, is this one past its window. A constant `LastModified` makes
  # every dump the same age, which is either always fresh or always stale
  # depending on the day the suite runs.
  test "an object is listed with the time it was put", %{credentials: creds} do
    {:ok, _} = Storage.ensure_bucket("sams-dumps", creds)
    :ok = Storage.put_object("sams-dumps", "dumps/prod/one.sql.gz", "PGDMP", creds)

    {:ok, [dump]} = Storage.list_dumps("sams-dumps", creds, prefix: "dumps/")

    {:ok, taken_at, _} = DateTime.from_iso8601(dump.taken_at)
    assert DateTime.diff(DateTime.utc_now(), taken_at, :second) < 60
  end

  # The bucket really does remove them, which is the whole of 8016: retention
  # enforced rather than hoped for. A fake that listed everything it was ever
  # given would fail that criterion against a rule working perfectly.
  test "an object past the window is not listed", %{credentials: creds, agent: agent} do
    {:ok, _} = Storage.ensure_bucket("sams-dumps", creds)
    :ok = Storage.put_lifecycle("sams-dumps", 14, creds)

    Fakes.Storage.put_object(
      agent,
      "sams-dumps",
      "dumps/prod/old.sql.gz",
      "PGDMP",
      DateTime.add(DateTime.utc_now(), -30, :day)
    )

    Fakes.Storage.put_object(agent, "sams-dumps", "dumps/prod/new.sql.gz", "PGDMP")

    {:ok, dumps} = Storage.list_dumps("sams-dumps", creds, prefix: "dumps/")

    assert Enum.map(dumps, & &1.key) == ["dumps/prod/new.sql.gz"]
  end
end
