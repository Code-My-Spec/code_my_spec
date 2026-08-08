defmodule CodeMySpec.CassetteFilteringTest do
  @moduledoc """
  A recorded cassette must not carry a live credential.

  Header filtering covers the way out — every provider here authenticates with
  `Authorization`. It does not cover the way back, and that is where the real
  exposure is: an OAuth refresh answers with a fresh access token and, for
  Resend, a rotated refresh token, both in the response *body*. A recording
  session that happens to cross a token expiry writes a live, long-lived
  credential into a file that gets committed, and nothing about the cassette
  looks unusual afterwards.

  These tests record against a local plug rather than a provider, so they cost
  nothing and can assert on the bytes that reach disk.
  """

  use ExUnit.Case, async: false

  alias CodeMySpecSpex.Case, as: SpexCase

  # What a recording would write, with the same filters applied. Driving the
  # recorder itself would need a real network target to proxy to, which buys
  # nothing here — the question is whether the filters redact, and that is
  # answerable directly.
  defp filtered(text) do
    Enum.reduce(SpexCase.sensitive_patterns(), text, fn {pattern, replacement}, acc ->
      Regex.replace(pattern, acc, replacement)
    end)
  end

  defp filtered_body(body) do
    %{"body_json" => body}
    |> SpexCase.redact_token_fields()
    |> Jason.encode!()
  end

  describe "the way back — response bodies" do
    test "a token refresh response does not write its tokens" do
      written =
        filtered_body(%{
          "access_token" => "live-access-token-abcdef123456",
          "refresh_token" => "live-rotated-refresh-abcdef",
          "expires_in" => 3600
        })

      refute written =~ "live-access-token-abcdef123456",
             "the access token from a refresh response would be written to the cassette"

      refute written =~ "live-rotated-refresh-abcdef",
             "the rotated refresh token would be written to the cassette"

      # Anchor: the body survives, so the refutes mean "redacted" rather than
      # "nothing was recorded".
      assert written =~ "expires_in"
      assert written =~ "REDACTED"
    end

    test "a token nested where no pattern anticipated it is still redacted" do
      written =
        filtered_body(%{
          "data" => %{"integration" => %{"access_token" => "buried-live-token-xyz"}},
          "ok" => true
        })

      refute written =~ "buried-live-token-xyz",
             "a nested token survived — the structural pass is not walking the body"

      assert written =~ "\"ok\":true"
    end
  end

  describe "the way out — request bodies and URLs" do
    test "form-encoded credentials are redacted" do
      written =
        filtered("grant_type=refresh_token&refresh_token=live-value-here&client_secret=shhh")

      refute written =~ "live-value-here"
      refute written =~ "shhh"
      assert written =~ "grant_type=refresh_token", "the non-secret fields should survive"
    end

    test "a presigned S3 URL keeps neither the key id nor the signature" do
      # SigV4 puts both in the query string, where a header filter never looks.
      written =
        filtered(
          "https://fsn1.your-objectstorage.com/b/o?X-Amz-Credential=AKIAEXAMPLE123%2F20260801%2Ffsn1" <>
            "&X-Amz-Signature=deadbeefcafe1234567890&X-Amz-Expires=900"
        )

      refute written =~ "AKIAEXAMPLE123"
      refute written =~ "deadbeefcafe1234567890"
      assert written =~ "X-Amz-Expires=900"
    end
  end

  describe "recognisable credential shapes" do
    # Not in any field a pattern names — the shape is the only signal, which is
    # exactly the case of a token echoed back inside an error message.
    test "are caught wherever they appear" do
      written =
        filtered(
          "token ghp_AbCdEfGhIjKlMnOpQrStUvWxYz012345 was rejected; " <>
            "key AGE-SECRET-KEY-1QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ"
        )

      refute written =~ "ghp_AbCdEfGhIjKlMnOpQrStUvWxYz012345"
      refute written =~ "AGE-SECRET-KEY-1QQQQQQQQQQQQQQQQQQQQQQQQQQQQQQ"
      assert written =~ "was rejected", "the surrounding message should survive"
    end
  end

  describe "the cassettes already in the repository" do
    # The audit, standing rather than one-off. A credential committed once is
    # committed forever as far as rotation is concerned, so this needs to fail
    # the build rather than be something somebody remembers to check.
    test "carry no recognisable credential" do
      # Credential *shapes*, not "any long string". A blunt length rule flags
      # every fixture token and trains people to ignore the failure, which is
      # worse than not having the check.
      shapes = [
        ~r/AGE-SECRET-KEY-[A-Z0-9]{10,}/,
        ~r/\bgh[pous]_[A-Za-z0-9]{30,}/,
        ~r/\bcfat_[A-Za-z0-9]{30,}/,
        ~r/\bre_[A-Za-z0-9_-]{30,}/,
        # A JWT with a real signature — three base64 segments, the last long
        # enough to be an actual RS256 signature rather than a stub.
        ~r/eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{200,}/
      ]

      # Anything self-evidently not a credential. Recorded fixtures say so.
      placeholder = ~r/test|fake|stub|example|redact|dummy|placeholder|spex/i

      # The replay keypairs are the one real age secret that belongs in the
      # repository: fixed, published in `CodeMySpecSpex.Case`, and holding
      # nothing but a temp directory during replay. They exist because the
      # previous placeholders were *shaped* like keys but invalid, so replay
      # produced a key that could not open what it had encrypted.
      #
      # Listed exactly rather than matched by shape. A pattern loose enough to
      # excuse these would excuse a real key too, and this audit failing loudly
      # is worth more than its convenience.
      known = SpexCase.replay_keypairs() |> Enum.map(&elem(&1, 1)) |> MapSet.new()

      offenders =
        for dir <- ["test/cassettes", "test/fixtures/cassettes"],
            File.dir?(dir),
            path <- Path.wildcard(Path.join(dir, "**/*.json")),
            contents = File.read!(path),
            pattern <- shapes,
            match = Regex.run(pattern, contents),
            match && not Regex.match?(placeholder, hd(match)),
            not MapSet.member?(known, hd(match)),
            do: path

      assert offenders == [],
             """
             These cassettes appear to carry a live credential:

             #{offenders |> Enum.uniq() |> Enum.map_join("\n", &("  " <> &1))}

             Re-record them after checking the filters in
             `CodeMySpecSpex.Case.with_provider_cassette/3`, and rotate whatever
             leaked — a credential committed once is committed for good.
             """
    end
  end
end
