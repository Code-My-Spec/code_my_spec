defmodule CmsHarness.HealthDegradedTest do
  @moduledoc """
  `/health` answers with evidence, not only with belief.

  `connected` is the harness's view of its own socket, set at join. It cannot
  be wrong from where it stands, and that is the problem: through the incident
  this endpoint exists to catch, it read `true` while the server's registry
  held no entry for this harness and every request came back unreachable.
  `/health` said `serving 3, degraded false` the whole time, so nothing
  suggested the one thing that fixed it — restarting the harness.

  `server_replied_ago_s` was added as the evidence half and reported next to
  the belief. It was never consulted, so the verdict a reader actually acts on
  still came from belief alone.

  The check here is deliberately narrow, and the second half of these tests is
  about what must *not* trip it. A harness nobody is working in goes hours
  without a reply; calling that degraded trades a false green for a false red,
  which is the same mistake in the other direction and would teach a reader to
  ignore the field.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.Web.HealthController

  defp project(attrs) do
    Map.merge(
      %{root: "/tmp/wc", connected: true, watching: true, server_replied_ago_s: 3, joined_ago_s: 900},
      attrs
    )
  end

  describe "what counts as degraded" do
    test "a channel that never joined is degraded, as it always was" do
      assert HealthController.degraded?(project(%{connected: false}))
    end

    test "joined, but the server has never once answered it" do
      # The incident exactly: the join succeeded locally, the server's registry
      # has no entry, and nothing on either side had done a round trip.
      assert HealthController.degraded?(
               project(%{connected: true, server_replied_ago_s: nil, joined_ago_s: 900})
             ),
             "a socket that believes it is open, well after joining, with the " <>
               "server having never addressed it, is the one reading that cannot be innocent"
    end
  end

  describe "what must not count as degraded" do
    test "a quiet harness that has been answered before is healthy" do
      # No reply for two hours because nobody is working in that checkout. This
      # is the false positive that would make the field worthless.
      refute HealthController.degraded?(
               project(%{connected: true, server_replied_ago_s: 7_200, joined_ago_s: 10_000})
             )
    end

    test "a channel that joined seconds ago is given its grace" do
      # Nothing has had time to answer it yet. Reporting degraded here would
      # fire on every harness start.
      refute HealthController.degraded?(
               project(%{connected: true, server_replied_ago_s: nil, joined_ago_s: 5})
             )
    end

    test "an unknown join time is not evidence of anything" do
      refute HealthController.degraded?(
               project(%{connected: true, server_replied_ago_s: nil, joined_ago_s: nil})
             )
    end

    test "the ordinary healthy case" do
      refute HealthController.degraded?(project(%{}))
    end
  end

  # The point of the whole change: belief and evidence can disagree, and when
  # they do the evidence wins. If this passes with the verdict reading
  # `connected` alone, the test is not testing anything.
  test "belief alone is no longer the verdict" do
    believes_connected =
      project(%{connected: true, server_replied_ago_s: nil, joined_ago_s: 900})

    assert believes_connected.connected
    assert HealthController.degraded?(believes_connected)
  end
end
