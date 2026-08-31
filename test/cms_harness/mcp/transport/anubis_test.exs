defmodule CmsHarness.Mcp.Transport.AnubisTest do
  @moduledoc """
  The transport's sibling name, against the name it is really derived from.

  This is one line of term-shuffling and it stopped every agent on every machine
  from starting for forty minutes. A malformed via tuple is a perfectly good
  term: nothing objects until a supervisor start deep inside Anubis does, and
  its complaint arrives as "the agent was not started on its machine", which
  reads like the machine's fault.

  So the assertion that matters is not "it returns something different" — the
  broken version did that too. It is that the result is still a name in
  `CmsHarness.Registry`, which is where the process it names has to live.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.Mcp.Transport.Anubis

  describe "transport_name/1" do
    test "keeps the registry and tags only the key" do
      # Exactly what CmsHarness.Mcp.name/2 builds. Written out rather than
      # called, so that a change to either one shows up here as a disagreement
      # rather than as two things moving together into the same hole.
      name = {:via, Registry, {CmsHarness.Registry, {:mcp, "agent-1", "http://x"}}}

      assert {:via, Registry, {registry, key}} = Anubis.transport_name(name)

      assert registry == CmsHarness.Registry,
             "the transport was named in #{inspect(registry)}. A Registry via tuple's " <>
               "third element is {registry_name, key}, so tagging the pair instead of " <>
               "the key invents a registry nobody started — ArgumentError: unknown " <>
               "registry, surfacing as an agent that will not start."

      assert key == {:transport, {:mcp, "agent-1", "http://x"}}
    end

    test "does not collide with the client it is a sibling of" do
      name = {:via, Registry, {CmsHarness.Registry, {:mcp, "agent-1", "http://x"}}}

      refute Anubis.transport_name(name) == name,
             "client and transport would register under one key, and the second to " <>
               "start would find the first already there."
    end

    test "two agents get two transports" do
      one = {:via, Registry, {CmsHarness.Registry, {:mcp, "agent-1", "http://x"}}}
      two = {:via, Registry, {CmsHarness.Registry, {:mcp, "agent-2", "http://x"}}}

      refute Anubis.transport_name(one) == Anubis.transport_name(two),
             "one session per agent is the whole point of naming these after the " <>
               "agent; two agents sharing a transport name means the second reads " <>
               "the first's replies."
    end

    test "an atom name gets the sibling Anubis derives itself" do
      assert Anubis.transport_name(SomeClient) == SomeClient.Transport
    end

    test "a global name is tagged in place" do
      assert Anubis.transport_name({:global, :browser}) == {:global, {:transport, :browser}}
    end
  end
end
