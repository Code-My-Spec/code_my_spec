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

  describe "issuance is waited for rather than caught mid-flight" do
    # kamal-proxy asks Let's Encrypt for the certificate when the service comes
    # up and stalls the handshake until it arrives, so one timed-out probe means
    # "not yet". This step used to make exactly one attempt and was the only
    # asynchronous thing in provisioning that did not poll.
    test "a certificate that arrives late still passes", ctx do
      # Per host, because the step fans out over environments and a shared
      # counter would mix one host's retries into the next host's tally.
      {:ok, calls} = Agent.start_link(fn -> %{} end)

      probe = fn host, _opts ->
        n = Agent.get_and_update(calls, &{Map.get(&1, host, 0) + 1, Map.update(&1, host, 1, fn c -> c + 1 end)})
        if n < 3, do: {:error, %Finch.TransportError{reason: :timeout}}, else: :ok
      end

      assert {:ok, resources} = Steps.run(:tls, ctx.scope, probe: probe)
      assert Enum.any?(resources, &(&1.kind == "certificate"))

      for {host, n} <- Agent.get(calls, & &1) do
        assert n == 3, "#{host} kept probing after it answered"
      end
    end

    test "it gives up rather than polling forever", ctx do
      counter = :counters.new(1, [])

      probe = fn _host, _opts ->
        :counters.add(counter, 1, 1)
        {:error, %Finch.TransportError{reason: :timeout}}
      end

      assert {:error, _message, _resources} =
               Steps.run(:tls, ctx.scope, probe: probe, tls_attempts: 4)

      # Four attempts, plus the single plain-HTTP observation the failure adds.
      assert :counters.get(counter, 1) == 5
    end
  end

  describe "a failure says which prerequisite is missing" do
    # The advice names DNS and port 80, and every drill so far had to guess
    # which one from a host teardown had already destroyed.
    test "port 80 answering points at issuance", ctx do
      probe = fn _host, opts ->
        if Keyword.get(opts, :scheme) == :http,
          do: :ok,
          else: {:error, %Finch.TransportError{reason: :timeout}}
      end

      assert {:error, message, _} = Steps.run(:tls, ctx.scope, probe: probe, tls_attempts: 1)
      assert message =~ "Port 80 does answer"
      assert message =~ "issuance itself"
    end

    test "port 80 silent points at reachability", ctx do
      probe = fn _host, _opts -> {:error, %Finch.TransportError{reason: :econnrefused}} end

      assert {:error, message, _} = Steps.run(:tls, ctx.scope, probe: probe, tls_attempts: 1)
      assert message =~ "Port 80 does not answer either"
      assert message =~ "reachability rather than issuance"
    end
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
