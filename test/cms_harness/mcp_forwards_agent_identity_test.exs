defmodule CmsHarness.McpForwardsAgentIdentityTest do
  @moduledoc """
  The proxy carries who is asking.

  `:4004/mcp` is this proxy, not `CodeMySpecLocalWeb.Endpoint`. It forwards an
  allowlist of headers and drops the rest in silence. `x-agent-id` was not on the
  list, so it never reached the server — and nothing anywhere reported that a
  header had been discarded.

  What that cost: `ask_user_question` decides who holds a question from
  `frame.assigns[:agent_id]`. With none it writes `agent_id NULL` and
  `holder: "user"`, so every question a locally-run agent asked went straight to
  the person, bypassing the main agent whose entire purpose is to answer it
  first. `QuestionsRepository` inner-joins on `agent_id`, so those rows were not
  merely misrouted — they were unreachable, and the main agent could not have
  intercepted them had it known they existed.

  Neither side showed a symptom. The person saw questions and assumed the main
  agent had judged them worth escalating. The main agent saw an empty list and
  assumed nobody was blocked.

  QA found the behaviour by driving the real endpoint and reading the row. The
  first fix then missed, putting `AgentScope` on `CodeMySpecLocalWeb`'s pipeline
  — a real gap, and a different door from this one. This test exists so the
  third attempt is not needed.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.Web.McpController

  test "x-agent-id is forwarded to the server" do
    assert "x-agent-id" in McpController.forwarded_headers(),
           """
           The proxy drops x-agent-id, so the server cannot tell which agent is
           calling.

           Consequence is not a missing convenience: ask_user_question falls back
           to holder "user" with a NULL agent_id, which both sends the question
           to the wrong place and makes the row unreachable to the tools that
           would have handled it.
           """
  end

  test "the headers the transport itself needs are still forwarded" do
    forwarded = McpController.forwarded_headers()

    for required <- ~w(accept content-type mcp-session-id mcp-protocol-version last-event-id) do
      assert required in forwarded,
             "#{required} is what the MCP transport itself runs on; dropping it breaks the session"
    end
  end

  test "authorization is not in the allowlist, because the proxy supplies its own" do
    refute "authorization" in McpController.forwarded_headers(),
           """
           The proxy authenticates with the harness credential and sets this
           header itself. Forwarding a client-supplied one would let a caller
           choose the identity the server authenticates as, which is a different
           thing entirely from naming an agent the server then verifies.
           """
  end
end
