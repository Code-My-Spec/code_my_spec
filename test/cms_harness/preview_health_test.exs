defmodule CmsHarness.PreviewHealthTest do
  @moduledoc """
  What a status code from a preview address means.

  The gate `code_on_running_copy` refuses a story whose application is `down`
  and lets one through whose application is `erroring`, on the grounds that a
  500 is the application answering and failing — which is what QA exists to
  meet — while a refused connection is nothing to test.

  That distinction is made here, and it was wrong on the day it shipped in the
  one topology every preview actually uses. Every preview address is a
  Cloudflare tunnel, so an application that is not running does not produce a
  refused connection: the edge answers 530 with Argo error 1033, "no origin
  connected". Measured live on three checkouts — two returned 530 with nothing
  running behind them, and the classifier called both `erroring`, which is the
  verdict that sends QA to a Cloudflare error page.
  """

  use ExUnit.Case, async: true

  alias CmsHarness.Sync

  describe "nothing is serving" do
    test "a refused connection or a timeout is down" do
      assert Sync.classify("000") == "down"
    end

    # The one that was wrong. 1033 arrives as 530 and means the tunnel has no
    # origin, which is the same fact as a refused connection wearing the edge's
    # clothes.
    test "a tunnel with no origin behind it is down" do
      assert Sync.classify("530") == "down"
    end

    test "the rest of the edge's origin-unreachable range is down too" do
      for code <- ~w(502 520 521 522 523 524 525 526 527) do
        assert Sync.classify(code) == "down",
               "#{code} is the edge saying it could not reach an application; " <>
                 "reading it as the application failing sends QA to an error " <>
                 "page with no application behind it"
      end
    end
  end

  describe "the application answered" do
    # Deliberately not `down`. An application that came up and is failing is
    # exactly the thing QA is for, and holding the story back would turn a
    # defect into a gate nobody is looking at.
    test "a server error from the application itself is erroring" do
      assert Sync.classify("500") == "erroring"
      assert Sync.classify("503") == "erroring"
    end

    test "anything that answered normally is serving" do
      for code <- ~w(200 302 401 404) do
        assert Sync.classify(code) == "serving"
      end
    end

    # A 404 is a route that is not there, not an application that is not there.
    # Named because the health check falls back to the root path on a project
    # with no `/health`, and a root that 404s is still a running application.
    test "a missing route is not a missing application" do
      assert Sync.classify("404") == "serving"
    end
  end

  test "an unreadable code is down rather than assumed fine" do
    assert Sync.classify("") == "down"
    assert Sync.classify("nonsense") == "down"
  end
end
