defmodule CodeMySpec.SpexGivensTest do
  @moduledoc """
  A `given_` has to make its precondition true, not merely state it.

  The failure this prevents is cheap to write and expensive to find. A block
  that says *"a version is deployed and serving"* and then only mounts a page
  has established nothing, so the run fails several steps later inside a
  `then_` — with a message about the thing under test rather than about the
  precondition that was never set up. On story 969 that happened four times,
  and each one cost a full ~10-minute cassette record cycle to trace back.

  ## What counts as establishing

  Driving the app: mounting a LiveView, clicking or submitting, an HTTP call,
  the `Fixtures` bridge, or one of the helpers named in `@establishes`.

  That last one is a list, not a category. Most of `CodeMySpecSpex.Case` does
  not drive anything — `spex_timeout/0` and `workspace_runner/0` are accessors —
  so "any Case helper" would pass blocks that establish nothing. A new helper
  that does drive the app has to be added to `@establishes` to count, and saying
  otherwise is what made this check refuse a block that had followed its own
  advice.

  The list is deliberately generous within that: this catches the block that
  does *nothing at all*, which is the version that always indicates the bug.

  It cannot catch the subtler case: a block that mounts a page while claiming
  a fact about the world the mount does not create. Those need reading. This
  is the floor, not the ceiling.
  """

  # Sync: this mutates OS environment variables, which belong to the BEAM node
  # rather than to a test process. Saving and restoring them is careful and
  # still leaves a window every concurrent test can see.

  use ExUnit.Case, async: false

  # `stage_` covers the family that seams a provider — stage_servers,
  # stage_containers, stage_inventory, stage_build, stage_deploy. Those are
  # `CodeMySpecSpex.Case` helpers, which the moduledoc above already counts as
  # establishing; the list simply predates them. A block saying "Sam runs two
  # servers he built himself" and calling `stage_servers/3` has made its
  # precondition true in the only way available — the provider is the thing
  # that decides, and the seam is how a criterion about *display* avoids
  # buying a machine to say so.
  # A channel is a public surface too. The widget half of a support conversation
  # has no other one — there is no page to mount, so joining the socket and
  # pushing to it IS driving the app. `join_widget` is listed by the same
  # precedent as `stage_`: a helper whose whole body is the drive.
  #
  # `System.cmd`, `System.put_env` and `System.delete_env` were removed from this
  # list, because `SpexDeniedCalls` (CMS0002) forbids all three inside a
  # `_spex.exs`. Listing them here told an author to establish a precondition by
  # writing exactly what the other check rejects, and the two together left a
  # `given_` about an environment variable with no legal way to be written
  # (5c50b880).
  #
  # `put_env!`/`delete_env!` replace them. They live on `CodeMySpecSpex.Case`,
  # mutate in support where CMS0002 does not reach, and restore on exit — so the
  # case that motivated the `System.*` entries in the first place ("no project id
  # is set in its environment", on a VM that really does export one because it
  # runs under a harness) is still establishable, just not by the spex reaching
  # for the VM itself.
  #
  # Removing them broke nothing, which is worth recording: no spex ever called
  # any of the three. All six files that matched did so through a *comment* —
  # 1013/criterion_2361 says "Through the environment, not `System.cmd`" and was
  # counted as establishing for saying so. This list is a substring match over
  # the whole block, comments included, so a block can still pass by describing
  # the drive it does not perform. That is a hole in the floor, not the floor.
  #
  # Nothing may be commented *inside* the sigil — ~w has no comments, so a `#`
  # line becomes literal words like "a" and "is", which match every body and
  # silently disable the whole check.
  # Four more that were already driving and were not being counted for it:
  #
  #   * `StoryHelpers.` — its own moduledoc says it "drives the same MCP tools
  #     the agent uses in production", which is the definition this list is
  #     for. `Fixtures.` is here on the same grounds.
  #   * `Artifacts.` — writes through the `Environments` seam, which is listed
  #     one line up, so listing the wrapper and not the wrapped was arbitrary.
  #   * `story_for` — story 460's local wrapper around
  #     `StoryHelpers.create_and_link/3`.
  #   * `register_and_log_in_user` — creates a user and a session for it. The
  #     `setup :`-shaped uses were never scanned; the one that reads it inside
  #     a `given_` (603/5502) was flagged for doing openly what the others do
  #     behind a setup.
  #
  # `seed_cookies` joins `assign` and `put_session` for the same reason they are
  # here: a request's state is part of the world a criterion drives, and story
  # 812's session-stitching criteria have no other way to say "a visitor
  # arriving with these GA cookies". The helper's whole body is
  # `Plug.Test.put_req_cookie/3` twice.
  #   * `given_a_main_checkout` — `CodeMySpecSpex.MainAgentHelpers`. It joins a
  #     working copy over the harness channel and clicks the control that
  #     designates it, so a block calling it has made a real checkout and made
  #     it the project's main one.
  #
  #   * `say_to_main_agent` — `CodeMySpecSpex.MainAgentHelpers`. It submits the
  #     composer on the conversation and waits for the turn, so a block calling
  #     it has put real messages in a real conversation. Story 966's "a
  #     conversation with more messages than fit on screen" has no other way to
  #     be true: the point of that premise is that the transcript is long, and
  #     the only thing that lengthens a transcript is talking to the agent.
  #
  #   * `EpicHelpers.` — story 964's premises. It drives `CreateEpic` and
  #     `AssignStoryToEpic` through their MCP tools and approves through the
  #     control on the epics screen, so a block calling it has established a
  #     real epic on a real working copy. The calls it makes into
  #     `EpicDispatch` are remote by name because that module is not written
  #     yet; that is what makes 964's specs red rather than what makes them
  #     establish nothing.
  #
  # `join_working_copy/3` and `report_agents/2` are `CodeMySpecSpex.WorkingCopyHelpers`
  # — both join a real channel and drive it the way the harness does. A working
  # copy exists *because* a harness joined for it, so joining is the establishing
  # act rather than a shortcut around one.
  #
  # Comments stay out here. `~w()` has no comment syntax, so a `#` line inside the
  # sigil becomes literal tokens — including every ordinary English word in it,
  # which then matches almost any given body and silently disables this check.
  @establishes ~w(
    Fixtures. live( render_click render_submit render_change element(
    post( put( patch( delete( dispatch( with_provider_cassette use_cmd_cassette
    .execute(
    mount_provisioning
    run_steps choose_setup_options all_setup_options own_domain built_deploy_run
    stage_servers
    existing_apex_mx paste_storage_credentials verified_sending_domains
    stuck_sending_domain unverifiable_domain app_holds_refresh_secret
    connect_providers tear_down_after Environments. File.write File.mkdir
    assign put_session seed_cookies
    StoryHelpers. Artifacts. story_for register_and_log_in_user
    stage_ scripted_run built_deploy_run devops_on
    subscribe_and_join ChannelTest. join_widget join_and_send
    put_env! delete_env!
    join_working_copy report_agents
    EpicHelpers. given_a_main_checkout say_to_main_agent
  )

  # The failure message has always offered a second remedy — "if the
  # precondition is genuinely already true, say so" — and there was no way to
  # say it. `scan/0` reads the body and never the title, so retitling changed
  # nothing and the only ways out were to fake an establishing call or to add
  # the file to a baseline that forbids additions.
  #
  # This is that remedy, made real. It is deliberately wordy and has to sit in
  # the body where a reader of the given sees it, because the claim it makes is
  # the one thing this check cannot verify: that something *else* already did
  # the work. Naming what did it is the price.
  @already_established "given: already true —"

  # `given_ "title", context do ... end` — closed by an `end` at the block's
  # own indentation, which is what makes the body extractable without parsing.
  @given_block ~r/^([ ]*)given_ ("(?:[^"\\]|\\.)*")(?:, \w+)? do\n(.*?)^\1end\n/ms

  # The 54 files that predate this check, from the codebase-wide sweep in
  # issue e693c4c9. A ratchet rather than an exemption: nothing may be added,
  # and a file leaving this list must never come back. The devops epic
  # (963-974, 985) is deliberately absent — it was cleared, and this test is
  # what keeps it cleared.
  @baseline [
    "test/spex/602_oauth_registration_logs_the_user_in_via_the_callback/criterion_5493_first_google_signup_creates_a_user_with_confirmed_at_set_spex.exs",
    "test/spex/602_oauth_registration_logs_the_user_in_via_the_callback/criterion_5495_second_google_sign-in_returns_the_same_user_with_no_duplicate_records_spex.exs",
    "test/spex/602_oauth_registration_logs_the_user_in_via_the_callback/criterion_5496_same_email_from_a_different_oauth_provider_links_to_the_existing_user_instead_of_creating_a_new_one_spex.exs",
    "test/spex/983_spec_failures_block_only_stories_whose_specs_have_gone_green/criterion_8161_a_later_edit_stales_the_spex_run_without_un-readying_the_story_spex.exs",
    "test/spex/983_spec_failures_block_only_stories_whose_specs_have_gone_green/criterion_8168_reaching_specs-ready_releases_qa_on_the_story_spex.exs"
  ]

  test "no new given_ block states a precondition without establishing it" do
    offenders = scan()
    new_offenders = Enum.reject(offenders, fn {path, _line, _title} -> path in @baseline end)

    assert new_offenders == [],
           """
           These given_ blocks state a precondition and do nothing to make it true:

           #{format(new_offenders)}

           A given_ should drive the app — mount the view, click, submit, make an
           HTTP call, use the Fixtures bridge, or call one of the establishing
           helpers.

           "One of the establishing helpers" is literal: this check matches an
           explicit list, `@establishes` in this file, not every function on
           `CodeMySpecSpex.Case`. Most of that module does not drive anything —
           `spex_timeout/0`, `workspace_runner/0` and `step_detail/2` are
           accessors, and counting them would make this check pass on blocks that
           establish nothing.

           So if you wrote a new Case helper that genuinely drives the app, add
           its name to `@establishes` in the same commit. That is the step, and
           an earlier version of this message did not mention it — it said "call
           a Case helper", which reads as though any of them will do, and left
           whoever followed it failing for a reason the message had ruled out.

           If the precondition is genuinely already true, say so in the body and
           name what made it true:

               # given: already true — `setup :setup_active_project` creates it.
           """
  end

  test "the baseline shrinks and never grows" do
    still_offending = scan() |> Enum.map(fn {path, _, _} -> path end) |> MapSet.new()
    stale = Enum.reject(@baseline, &MapSet.member?(still_offending, &1))

    assert stale == [],
           """
           These files were fixed but are still listed in @baseline:

           #{Enum.map_join(stale, "\n", &("  " <> &1))}

           Remove them. A baseline that keeps fixed files lets them regress
           silently, which is the one thing it exists to prevent.
           """
  end

  defp scan do
    for path <- Path.wildcard("test/spex/**/*_spex.exs"),
        source = path |> File.read!() |> blank_heredocs(),
        [whole, indent, title, body] <- Regex.scan(@given_block, source),
        not String.contains?(strip_comments(body), @establishes),
        not String.contains?(body, @already_established) do
      _ = whole
      offset = source |> String.split(indent <> "given_ " <> title) |> hd()
      {path, length(String.split(offset, "\n")), String.trim(title, ~s("))}
    end
  end

  # Matched against code, not prose. A comment saying `live(` is a block
  # describing a drive it does not perform, and this check exists to catch a
  # block that does nothing at all — the version that always indicates the bug.
  #
  # Measured before changing it: **zero** `given_` blocks in the suite pass only
  # because of a comment, so this closes the hole at no cost rather than
  # starting a migration. The measurement was checked against a synthetic
  # comment-only block first, because a zero from a probe that cannot return
  # anything else is not a finding.
  #
  # `@already_established` is deliberately matched against the raw body: that
  # marker *is* a comment, and stripping it here would delete the one escape
  # hatch this check offers.
  #
  # Whole-line comments only. A `#` inside a heredoc line would be stripped too,
  # which could flag a block whose only establishing call sits in such a line —
  # no block in the suite is shaped that way, and the test itself would catch it.
  # A spex that writes a spec file writes spex source, and story 460 does
  # exactly that: five of its criteria embed an example
  #
  #     given_ "setup", _context do
  #       :ok
  #     end
  #
  # inside a heredoc, as the fixture whose parsing is under test. Scanning raw
  # text cannot tell that from code, so all five were offenders for containing
  # a picture of one — and sat on the baseline for it.
  #
  # Blanked rather than deleted, line for line, so the line numbers this
  # reports still point at the right place in the file.
  defp blank_heredocs(source) do
    source
    |> String.split("\n")
    |> Enum.map_reduce(false, fn line, inside? ->
      blank_line(line, inside?, String.contains?(line, ~s(""")))
    end)
    |> elem(0)
    |> Enum.join("\n")
  end

  # {line, inside-a-heredoc?, is-a-delimiter-line?} -> {what to keep, still inside?}
  defp blank_line(line, false, false), do: {line, false}
  defp blank_line(line, false, true), do: {line, true}
  defp blank_line(_line, true, false), do: {"", true}
  defp blank_line(_line, true, true), do: {"", false}

  defp strip_comments(body) do
    body
    |> String.split("\n")
    |> Enum.map_join("\n", &Regex.replace(~r/^\s*#.*$/, &1, ""))
  end

  defp format(offenders) do
    Enum.map_join(offenders, "\n", fn {path, line, title} -> "  #{path}:#{line}  #{title}" end)
  end
end
