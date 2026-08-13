defmodule CodeMySpec.Provisioning.TransportTest do
  @moduledoc """
  The formatter that turns a socket error into a sentence.

  This exists as its own test because the bug it prevents was invisible from
  above: `TlsMessageTest` asserted the tls step renders `%Finch.TransportError{}`
  in words, and it does — but the production probe inspected the struct into a
  binary before the formatter ever saw it, and binaries pass through untouched.
  Four consecutive drills reported `%Req.TransportError{reason: :timeout}` on a
  page whose test suite said that could not happen.

  So the cases below name the wrappers by hand. Req, Finch and Mint all carry
  the reason on `:reason`, and the point is that the module does not care which
  one it was handed.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Provisioning.Transport

  describe "wrappers are unwrapped whoever produced them" do
    test "a Req transport error reads as words" do
      assert Transport.describe(%Req.TransportError{reason: :timeout}) ==
               "the host did not answer in time"
    end

    test "a Finch transport error reads the same" do
      assert Transport.describe(%Finch.TransportError{reason: :econnrefused}) ==
               "nothing is listening on that port"
    end

    # Finch nests an identical Mint error inside its own. Matching the outer
    # `:reason` is what keeps the inner one from being printed twice.
    test "a nested Finch/Mint pair yields one sentence" do
      nested = %Finch.TransportError{
        reason: :nxdomain,
        source: %Mint.TransportError{reason: :nxdomain}
      }

      assert Transport.describe(nested) == "the name does not resolve yet"
    end

    test "an error tuple is unwrapped" do
      assert Transport.describe({:error, :ehostunreach}) == "the host is unreachable"
    end
  end

  describe "terms that are not transport failures" do
    test "an already-formatted binary is left alone" do
      assert Transport.describe("responded 502") == "responded 502"
    end

    # A word rather than a struct, even with no sentence written for it.
    test "an unnamed atom still reads as a word" do
      assert Transport.describe(:econnaborted) == "econnaborted"
    end

    test "a term nobody anticipated is shown rather than guessed at" do
      assert Transport.describe(%{unexpected: true}) =~ "unexpected"
    end
  end

  describe "the struct never reaches the caller" do
    # The actual regression: whatever goes in, no `%…TransportError{}` comes
    # out, because what comes out gets interpolated into a sentence.
    for reason <- [
          %Req.TransportError{reason: :timeout},
          %Finch.TransportError{reason: :econnrefused},
          %Mint.TransportError{reason: :closed}
        ] do
      test "#{inspect(reason)} is never rendered as a struct" do
        described = Transport.describe(unquote(Macro.escape(reason)))

        refute described =~ "TransportError"
        refute described =~ "reason:"
      end
    end
  end
end
