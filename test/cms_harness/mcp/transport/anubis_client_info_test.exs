defmodule CmsHarness.Mcp.Transport.AnubisClientInfoTest do
  @moduledoc """
  One `client_info["name"]` per session, because Anubis keys an ETS table on it.

  `Anubis.Client.Cache` derives `:"anubis_client_<name>_tool_validators"` from
  that string and creates it `:private`, so the table belongs to whichever
  client reached it first and no other process can touch it. A constant name
  therefore allows exactly one working session per VM — the browser starts at
  boot and takes it, and every agent afterwards dies on `insufficient access
  rights`, which surfaces as `:start_timed_out`.

  Thirteen agent starts failed that way in a row before anyone looked, because
  "the agent was not started on its machine" reads as a machine problem.

  This is a unit test over the naming alone. The end-to-end proof is three
  sessions in one VM against the running server, which returns 15 tools each on
  this code and dies after the first on the constant.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.Mcp.Transport.Anubis

  # Anubis's own derivation, copied rather than called: the point is to notice
  # if it stops matching, not to agree with it by construction.
  defp table(%{"name" => name}), do: :"anubis_client_#{name}_tool_validators"

  defp session(agent_id),
    do: {:via, Registry, {CmsHarness.Registry, {:mcp, agent_id, "http://localhost:4000"}}}

  test "two agents do not share a validator table" do
    one = Anubis.client_info(session("agent-1"))
    two = Anubis.client_info(session("agent-2"))

    refute table(one) == table(two),
           "both agents would key #{inspect(table(one))}, which Anubis creates :private. " <>
             "The second agent to start cannot write to the first's table and dies on " <>
             "insufficient access rights — reported as :start_timed_out, which names " <>
             "neither the table nor the collision."
  end

  test "an agent does not share one with the browser" do
    agent = Anubis.client_info(session("agent-1"))
    browser = Anubis.client_info({:global, :cms_harness_browser})

    refute table(agent) == table(browser),
           "the browser starts at boot, so sharing a table with it means no agent on " <>
             "this machine ever gets a session."
  end

  test "the same session keeps the same name" do
    assert Anubis.client_info(session("agent-1")) == Anubis.client_info(session("agent-1")),
           "a name that changes between calls would leak an atom per call rather than " <>
             "per session, and Anubis interns each one."
  end

  test "the name still says who we are" do
    %{"name" => name} = Anubis.client_info(session("agent-1"))

    assert name =~ "cms-harness",
           "this reaches the server as clientInfo and is what a person reads in a log " <>
             "line to tell our sessions from anyone else's."

    assert name =~ "agent-1"
  end
end
