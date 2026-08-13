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
    Steps.run(
      :tls,
      scope,
      [probe: fn _host, _opts -> {:error, reason} end] ++ unresolvable()
    )
  end

  @timeout %Finch.TransportError{reason: :timeout}

  # The failure path asks a public resolver whether the record exists, which is
  # a real DNS-over-HTTPS request. Stubbed here, or this file would reach the
  # network to decide what a test asserts — the exact instrument problem that
  # let the transport-formatter bug survive.
  defp unresolvable, do: [resolver: fn _url -> {:error, :stubbed} end]

  defp resolvable do
    [resolver: fn _url -> {:ok, %{status: 200, body: %{"Answer" => [%{"data" => "1.2.3.4"}]}}} end]
  end

  # Counted per host, because the step fans out over environments and a shared
  # tally would mix one host's retries into the next host's.
  defp count_call(calls, host) do
    Agent.get_and_update(calls, fn seen ->
      n = Map.get(seen, host, 0) + 1
      {n, Map.put(seen, host, n)}
    end)
  end

  # A certificate that shows up on the third ask, which is the whole point:
  # issuance is asynchronous and the first answers are "not yet".
  defp answer_on_third(3), do: :ok
  defp answer_on_third(n) when n < 3, do: {:error, @timeout}

  # A proxy that is reachable on 80 and has no certificate on 443 — the state
  # that means issuance failed rather than that nothing is listening.
  defp answer_by_scheme(:http), do: :ok
  defp answer_by_scheme(_https), do: {:error, @timeout}

  describe "issuance is waited for rather than caught mid-flight" do
    # kamal-proxy asks Let's Encrypt for the certificate when the service comes
    # up and stalls the handshake until it arrives, so one timed-out probe means
    # "not yet". This step used to make exactly one attempt and was the only
    # asynchronous thing in provisioning that did not poll.
    test "a certificate that arrives late still passes", ctx do
      # Per host, because the step fans out over environments and a shared
      # counter would mix one host's retries into the next host's tally.
      {:ok, calls} = Agent.start_link(fn -> %{} end)

      probe = fn host, _opts -> calls |> count_call(host) |> answer_on_third() end

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
               Steps.run(
                 :tls,
                 ctx.scope,
                 [probe: probe, tls_attempts: 4] ++ unresolvable()
               )

      # Four attempts, plus the single plain-HTTP observation the failure adds.
      assert :counters.get(counter, 1) == 5
    end
  end

  describe "a failure says which prerequisite is missing" do
    # The advice names DNS and port 80, and every drill so far had to guess
    # which one from a host teardown had already destroyed.
    test "port 80 answering points at issuance", ctx do
      probe = fn _host, opts -> opts |> Keyword.get(:scheme) |> answer_by_scheme() end

      assert {:error, message, _} =
               Steps.run(:tls, ctx.scope, [probe: probe, tls_attempts: 1] ++ unresolvable())

      assert message =~ "Port 80 does answer"
      assert message =~ "issuance itself"
    end

    test "port 80 silent points at reachability", ctx do
      probe = fn _host, _opts -> {:error, %Finch.TransportError{reason: :econnrefused}} end

      assert {:error, message, _} =
               Steps.run(:tls, ctx.scope, [probe: probe, tls_attempts: 1] ++ unresolvable())

      assert message =~ "Port 80 does not answer either"
      assert message =~ "reachability rather than issuance"
    end
  end

  describe "a failure says which resolver disagreed" do
    # Two resolvers are in play: the dns step verifies over DNS-over-HTTPS, this
    # step's probe goes through the system resolver. They answer differently for
    # the same name whenever a recursive resolver is still holding the negative
    # answer it cached before the record was written — which reads as a broken
    # deployment and is a stale cache on this machine.
    test "a record a public resolver can see blames this machine's cache", ctx do
      probe = fn _host, _opts -> {:error, %Finch.TransportError{reason: :nxdomain}} end

      assert {:error, message, _} =
               Steps.run(:tls, ctx.scope, [probe: probe, tls_attempts: 1] ++ resolvable())

      assert message =~ "A public resolver does return an A record"
      assert message =~ "stale negative answer"
    end

    test "a record nobody can see is a missing record", ctx do
      probe = fn _host, _opts -> {:error, %Finch.TransportError{reason: :nxdomain}} end

      assert {:error, message, _} =
               Steps.run(:tls, ctx.scope, [probe: probe, tls_attempts: 1] ++ unresolvable())

      assert message =~ "No public resolver returns an A record"
      assert message =~ "the record is missing"
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
