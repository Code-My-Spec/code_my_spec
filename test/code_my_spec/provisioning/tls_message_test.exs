defmodule CodeMySpec.Provisioning.TlsMessageTest do
  @moduledoc """
  What the tls step says when the probe cannot reach the host.

  The provider's own error has to reach through rather than being swallowed
  (criterion 7962), and it does. The question here is what it looks like when
  it arrives on a page a human reads.

  Finch wraps Mint, so an unformatted transport failure reads as
  `%Finch.TransportError{reason: :econnrefused, source: %Mint.TransportError{reason:
  :econnrefused}}` — the same word twice, nested, in a shape only an Elixir
  developer can parse, with the layout truncating it mid-struct. `:econnrefused`
  is the entire payload; everything around it is noise.

  These assert the sentence, not the struct, because the sentence is the thing
  a user acts on.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Projects
  alias CodeMySpec.Provisioning.Steps

  setup do
    scope = full_scope_fixture()

    {:ok, project} =
      Projects.update_project(scope, scope.active_project, %{domain: "uat.example.com"})

    {:ok, scope: %{scope | active_project: project}}
  end

  defp run_tls(scope, reason) do
    Steps.run(:tls, scope, probe: fn _host, _opts -> {:error, reason} end)
  end

  describe "a transport failure is reported in words" do
    test "a refused connection says nothing is listening", ctx do
      assert {:error, message, _resources} =
               run_tls(ctx.scope, %Finch.TransportError{reason: :econnrefused})

      assert message =~ "nothing is listening on that port"

      refute message =~ "TransportError",
             "the struct reached the page instead of the sentence"

      refute message =~ "econnrefused",
             "the raw atom is the thing being translated"
    end

    test "a timeout says the host did not answer", ctx do
      assert {:error, message, _resources} =
               run_tls(ctx.scope, %Finch.TransportError{reason: :timeout})

      assert message =~ "the host did not answer in time"
      refute message =~ "TransportError"
    end

    # Finch nests an identical Mint error inside its own. Matching on the outer
    # `:reason` is what keeps the inner one from being printed.
    test "a nested Finch/Mint pair still reads as one sentence", ctx do
      nested = %Finch.TransportError{
        reason: :nxdomain,
        source: %Mint.TransportError{reason: :nxdomain}
      }

      assert {:error, message, _resources} = run_tls(ctx.scope, nested)

      assert message =~ "the name does not resolve yet"
      refute message =~ "Mint"
      refute message =~ "source:"
    end

    # The surrounding advice is the point of the sentence — it says what
    # issuance actually needs, which is what turns a failure into a next step.
    test "the advice survives the formatting", ctx do
      assert {:error, message, _resources} =
               run_tls(ctx.scope, %Finch.TransportError{reason: :econnrefused})

      assert message =~ "uat.example.com"
      assert message =~ "did not answer over HTTPS with a valid certificate"
      assert message =~ "DNS resolving to the server and the proxy reachable on 80"
    end
  end
end
