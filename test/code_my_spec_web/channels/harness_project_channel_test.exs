defmodule CodeMySpecWeb.HarnessProjectChannelTest do
  @moduledoc """
  The claim this channel exists to make: **the channel is the lease**.

  Joining takes the project's advisory lock on a connection the channel owns,
  so leaving — or dying, or losing the network — frees it with no deadline to
  wait out. These drive the channel rather than the Leases API directly,
  because the property under test is about the channel's lifetime.
  """

  # Not async: advisory locks are per-database, so concurrent tests taking them
  # are genuinely sharing state even with sandboxed rows.
  use CodeMySpecTest.DataCase, async: false

  import CodeMySpec.DevicesFixtures

  import Phoenix.ChannelTest
  import CodeMySpec.ComponentsFixtures
  import CodeMySpec.ProblemsFixtures
  import CodeMySpec.UsersFixtures

  @endpoint CodeMySpecWeb.Endpoint

  alias CodeMySpec.Analysis.RunsRepository
  alias CodeMySpec.FileEdits
  alias CodeMySpec.Files
  alias CodeMySpec.WorkingCopies
  alias CodeMySpecWeb.HarnessProjectChannel
  alias CodeMySpecWeb.UserSocket
  alias Ecto.Adapters.SQL.Sandbox

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})

    scope = full_scope_fixture()
    %{scope: scope, topic: "harness_project:#{scope.active_project_id}"}
  end

  # Mirrors what `UserSocket.connect/2` actually assigns: a scope, and for a
  # sprite a `:deploy_key_project_id`. Nothing else. The previous version of this
  # helper hand-injected `:harness_label`, an assign nothing in production ever
  # sets — which is precisely why the "name the checkout" property passed here
  # while every real refusal said "an unknown host".
  defp harness_socket(scope, opts) do
    socket(UserSocket, "harness_test", socket_assigns(scope, opts[:deploy_key_project_id]))
  end

  defp socket_assigns(scope, nil), do: %{scope: scope}
  defp socket_assigns(scope, project_id), do: %{scope: scope, deploy_key_project_id: project_id}

  @label "the harness at /workspace/app"

  # Joins as the working copy this scope represents, rather than minting a
  # stranger: files and problems are keyed on the harness now, so a test that
  # writes through the channel and reads through `scope` has to be the same
  # checkout on both sides. Tests about *minting* pass an explicit id instead.
  # `terminate/2` is where the reason is read, and an ordinary `leave` does not
  # carry one. Calling it on the channel process is what puts the reason through
  # the path under test.
  defp terminate_channel(socket, reason) do
    CodeMySpecWeb.HarnessProjectChannel.terminate(reason, socket)
  end

  defp join_as(scope, topic, opts \\ []) do
    scope
    |> harness_socket(opts)
    |> subscribe_and_join(HarnessProjectChannel, topic, %{
      "label" => @label,
      "harness_id" => scope.active_working_copy_id,
      "device" => %{"id" => device_fixture(scope).id}
    })
  end

  describe "the identity a working copy is issued" do
    # Story 727. Files and problems are projections of a working copy but have
    # only ever been keyed by project, so two checkouts write the same rows and
    # each sync deletes what the other just wrote. The id issued here is the
    # grain that fixes it, and it is issued *here* rather than derived on the
    # client because every client-derived alternative collides on a real case —
    # two containers at /workspace/app, a generated hostname, a churning
    # session id.
    defp join_with(scope, topic, working_copy_id) do
      # A join names its machine or it is refused: a checkout is identified by
      # {project, device, root}, and without a device two boxes at one path are
      # one row.
      payload = %{
        "label" => @label,
        "harness_id" => working_copy_id,
        "device" => %{"id" => device_fixture(scope).id}
      }

      scope
      |> harness_socket([])
      |> subscribe_and_join(HarnessProjectChannel, topic, payload)
    end

    # Only the wire contract lives here — that the id makes the round trip. The
    # minting rules are `CodeMySpec.WorkingCopies`' and are tested there, where a
    # second working copy does not have to get past a lease held by the first.
    test "a checkout joining for the first time is issued one", %{scope: scope, topic: topic} do
      assert {:ok, %{working_copy_id: id}, _socket} = join_with(scope, topic, nil)

      assert {:ok, _} = Ecto.UUID.cast(id),
             "the harness writes this down; without it every restart is a new harness"
    end

    test "presenting an id gets that same id back", %{scope: scope, topic: topic} do
      {:ok, harness} =
        WorkingCopies.issue(scope, nil, label: @label, device: device_fixture(scope))

      assert {:ok, %{working_copy_id: returned}, _socket} = join_with(scope, topic, harness.id)

      assert returned == harness.id,
             "a restart issued a second id orphans everything filed under the first"
    end
  end

  describe "joining" do
    test "a harness takes the project when it is free", %{scope: scope, topic: topic} do
      assert {:ok, _reply, _socket} =
               join_as(scope, topic)
    end

    # The refusal is per working copy now, not per project. Two processes on one
    # checkout read the same id out of the same gitignored file, so they contend;
    # two checkouts hold different ids and both serve, which is the whole point
    # of the grain change.
    test "a second harness on the same working copy is refused", %{scope: scope, topic: topic} do
      {:ok, %{working_copy_id: id}, _first} = join_with(scope, topic, nil)

      assert {:error, %{reason: "working_copy_in_use"}} = join_with(scope, topic, id),
             "not for the files — two processes read one disk and agree — but for the " <>
               "toolchain: two mix runs in one _build corrupt it"
    end

    test "two working copies of one project both serve", %{scope: scope, topic: topic} do
      assert {:ok, %{working_copy_id: first}, _} = join_with(scope, topic, nil)

      assert {:ok, %{working_copy_id: second}, _} = join_with(scope, topic, nil),
             "this is what the lease used to prevent, and what story 727 is for"

      refute first == second
    end

    test "a harness cannot join a project its scope does not cover", %{scope: scope} do
      other = full_scope_fixture()

      assert {:error, %{reason: "unauthorized"}} =
               join_as(scope, "harness_project:#{other.active_project_id}")
    end

    test "an unknown topic shape is refused", %{scope: scope} do
      assert {:error, %{reason: "invalid topic"}} =
               join_as(scope, "nonsense:1")
    end

    # Authorization used to compare the topic against `scope.active_project_id`,
    # which is the user's *UI preference* — the project they last clicked in the
    # web app. That capped a laptop at one project, the opposite of the
    # one-harness-many-projects design.
    test "a harness can hold a second project in the same account", %{scope: scope} do
      {:ok, other} =
        CodeMySpec.Projects.create_project(scope, %{
          name: "another-project-#{System.unique_integer([:positive])}",
          module_name: "Another"
        })

      assert {:ok, _reply, _channel} = join_as(scope, "harness_project:#{other.id}"),
             "a harness serves every project its credential reaches, not just the last one clicked"
    end

    # The sprite case, which was refused outright: the deploy-key connect assigns
    # `:deploy_key_project_id`, and resolving through the account owner's UI
    # preference meant a sprite was judged against whatever they last clicked.
    test "a deploy key reaches its own project", %{scope: scope, topic: topic} do
      assert {:ok, _reply, _channel} =
               join_as(scope, topic, deploy_key_project_id: scope.active_project_id)
    end

    test "a deploy key reaches nothing else", %{scope: scope} do
      {:ok, other} =
        CodeMySpec.Projects.create_project(scope, %{
          name: "not-mine-#{System.unique_integer([:positive])}",
          module_name: "NotMine"
        })

      assert {:error, %{reason: "unauthorized"}} =
               join_as(scope, "harness_project:#{other.id}",
                 deploy_key_project_id: scope.active_project_id
               ),
             "a deploy key is issued per project and must not reach a sibling"
    end

    # The label used to exist for refusals — "go and stop the harness at X". Two
    # checkouts both serve now, so nothing is refused for being elsewhere, and
    # the label's job is the operator's list instead. A harness that does not say
    # where it is still says so there, rather than having a host invented for it.
    test "a harness that does not say where it is is recorded that way",
         %{scope: scope, topic: topic} do
      # Says which machine and nothing else. Not saying the machine is a
      # different failure with its own refusal now, and this criterion is about
      # the root — a payload naming neither would be asserting the wrong one.
      {:ok, %{working_copy_id: id}, _first} =
        scope
        |> harness_socket([])
        |> subscribe_and_join(HarnessProjectChannel, topic, %{
          "device" => %{"id" => device_fixture(scope).id}
        })

      harness = Enum.find(WorkingCopies.list_harnesses(scope), &(&1.id == id))

      assert harness.label =~ "did not say where it is"
    end
  end

  # A restart and a disconnect read identically from inside an agent, and only
  # one of them is about the working copy. `terminate/2` recorded both as
  # `:harness_disconnected`, which sent three separate investigations after
  # harness problems that did not exist — a 12-minute spex sweep returning
  # `:not_connected`, a completed sweep whose latch did not flip, and three
  # hours of no sweeps read as analyzer-queue starvation. Each ended at
  # "somebody else restarted :4000" (406f85db).
  #
  # Phoenix drains channels on shutdown, so `{:shutdown, :draining}` is the
  # server going away. One harness serves every working copy of a project, so a
  # single restart fails the running set for all of them at once.
  describe "why an in-flight run was failed" do
    setup %{scope: scope, topic: topic} do
      {:ok, _reply, socket} = join_as(scope, topic)

      {:ok, run} =
        RunsRepository.start_run(scope, %{source: "spex", kind: :full})

      %{socket: socket, run: run}
    end

    test "a server restart says so, with the time", ctx do
      terminate_channel(ctx.socket, {:shutdown, :draining})

      assert %{stats: %{"error" => error}} =
               RunsRepository.get_run_in_project(ctx.scope, ctx.run.id)

      assert error =~ "shared dev server was restarted"
      assert error =~ "not by anything in your working copy"
    end

    # The other half. A harness that genuinely went away must not claim a
    # restart happened — that would send the reader to the wrong place just as
    # surely, in the other direction.
    test "an ordinary disconnect still reads as one", ctx do
      terminate_channel(ctx.socket, {:shutdown, :closed})

      assert %{stats: %{"error" => error}} =
               RunsRepository.get_run_in_project(ctx.scope, ctx.run.id)

      assert error =~ "harness_disconnected"
      refute error =~ "restarted"
    end
  end

  describe "read_model" do
    test "hands back everything a database-less harness needs to scan",
         %{scope: scope, topic: topic} do
      {:ok, _reply, channel} =
        join_as(scope, topic)

      ref = push(channel, "read_model", %{})

      assert_reply ref, :ok, payload, 2_000

      # The Scanner's own moduledoc names these as the only things it needs
      # from the domain; everything else it derives from the working copy.
      assert Map.has_key?(payload, "component_by_module")
      assert Map.has_key?(payload, "component_by_id")
      assert is_list(payload["story_ids"]), "a MapSet has no JSON form — it must cross as a list"
      assert is_boolean(payload["strict"])
    end

    # `assert_reply` compares terms in-process, so it never exercises the
    # serializer — which is how a reply carrying whole `%Component{}` structs
    # passed here while raising on a real socket. Components have no
    # `@derive Jason.Encoder`, so the harness received no read model at all.
    test "the reply can actually be encoded for the wire", %{scope: scope, topic: topic} do
      component_fixture(scope)

      {:ok, _reply, channel} = join_as(scope, topic)

      ref = push(channel, "read_model", %{})
      assert_reply ref, :ok, payload, 2_000

      assert {:ok, json} = Jason.encode(payload),
             "the read model has to survive JSON — asserting on the term in-process does not check that"

      # And only the one field its reader asks for: `component_by_id` is read
      # solely for `.module_name`, so shipping the row was a crash and several
      # kilobytes per component of fields nobody reads.
      decoded = Jason.decode!(json)

      for {_id, component} <- decoded["component_by_id"] do
        assert Map.keys(component) == ["module_name"]
      end
    end
  end

  describe "observations" do
    setup %{scope: scope, topic: topic} do
      {:ok, _reply, channel} =
        join_as(scope, topic)

      %{channel: channel}
    end

    test "a manifest becomes File rows", %{channel: channel, scope: scope} do
      ref =
        push(channel, "observations", %{
          "observations" => [
            %{
              "path" => "lib/todo/accounts.ex",
              "role" => "implementation",
              "mtime" => "2026-07-28T10:00:00.000000Z",
              "size" => 120,
              "fingerprint" => "abc123",
              "valid" => true,
              "validation_errors" => %{}
            }
          ]
        })

      assert_reply ref, :ok, %{"status" => "accepted", "observations" => 1}, 2_000

      assert [%{path: "lib/todo/accounts.ex", role: :implementation}] =
               CodeMySpec.Files.list_files(scope)
    end

    # Reconciling files is half a sync. The half that was missing here writes
    # `component_id` back onto each File row, and without it every
    # `implementation_file` requirement stays open forever — the check is scoped
    # to a component's own files, so a file nothing owns is invisible to it.
    #
    # Drill 11 finished the entire project chain, wrote every module, passed 157
    # tests, and still reported 15 implementation requirements unsatisfied with
    # all 66 implementation files synced and not one linked. The agent read that
    # as a dead file watcher. Sync was working perfectly; only the second half
    # was never being run on this path.
    test "a manifest also links files to their components", %{channel: channel, scope: scope} do
      ref =
        push(channel, "observations", %{
          "observations" => [
            %{
              "path" => ".code_my_spec/spec/todo/accounts.spec.md",
              "role" => "spec",
              "mtime" => "2026-07-28T10:00:00.000000Z",
              "size" => 80,
              "fingerprint" => "spec-1",
              "valid" => true,
              "validation_errors" => %{
                "errors" => %{},
                "data" => %{"module_name" => "Todo.Accounts", "type" => "context"}
              }
            },
            %{
              "path" => "lib/todo/accounts.ex",
              "role" => "implementation",
              "mtime" => "2026-07-28T10:00:00.000000Z",
              "size" => 120,
              "fingerprint" => "impl-1",
              "valid" => true,
              "validation_errors" => %{
                "errors" => %{},
                "data" => %{"module_name" => "Todo.Accounts"}
              }
            }
          ]
        })

      assert_reply ref, :ok, %{"status" => "accepted", "observations" => 2}, 2_000

      impl =
        scope
        |> CodeMySpec.Files.list_files()
        |> Enum.find(&(&1.path == "lib/todo/accounts.ex"))

      assert impl.component_id,
             "the implementation file synced but nothing owns it, so " <>
               "`implementation_file` can never be satisfied"
    end

    # The harness fetches its read model once, on join. A sprite joins before the
    # project has any stories, so its `story_ids` stays empty all session and it
    # refuses to link any spex file to any story — correct against a fresh read
    # model, exactly wrong against a stale one.
    #
    # Drill 12 wrote 32 spec files across 9 stories. All 32 synced; none carried
    # a story id, so `bdd_specs_exist` failed for every story and gated all 69
    # `implementation_file` requirements behind it. The manifest here carries no
    # ownership at all — the harness cannot know it — and the server has to
    # supply it.
    test "the server decides ownership, not the harness", %{channel: channel, scope: scope} do
      story = CodeMySpec.StoriesFixtures.story_fixture(scope)
      # The story's durable number, which is what a spex directory is named
      # from — the harness writes the path and the server resolves it back.
      dir = "test/spex/#{story.number}_some_title"

      ref =
        push(channel, "observations", %{
          "observations" => [
            %{
              "path" => "#{dir}/criterion_1_a_thing_happens_spex.exs",
              "role" => "bdd_spec",
              "mtime" => "2026-07-28T10:00:00.000000Z",
              "size" => 40,
              "fingerprint" => "spex-1",
              "valid" => true,
              "validation_errors" => %{}
            }
          ]
        })

      assert_reply ref, :ok, %{"status" => "accepted", "observations" => 1}, 2_000

      [file] = CodeMySpec.Files.list_files(scope)

      assert file.story_id == story.id,
             "the spec synced but belongs to no story, so `bdd_specs_exist` can " <>
               "never pass — and everything gated behind it stays unreachable"
    end

    # The manifest is the whole truth, so a path's absence is a deletion. This
    # is the reason it's sent whole rather than as a delta.
    test "a path missing from the next manifest is removed", %{channel: channel, scope: scope} do
      observation = fn path ->
        %{
          "path" => path,
          "role" => "implementation",
          "mtime" => "2026-07-28T10:00:00.000000Z",
          "size" => 10,
          "fingerprint" => "f-" <> path,
          "valid" => true,
          "validation_errors" => %{}
        }
      end

      ref =
        push(channel, "observations", %{
          "observations" => [observation.("a.ex"), observation.("b.ex")]
        })

      assert_reply ref, :ok, %{"status" => "accepted", "observations" => 2}, 2_000

      ref = push(channel, "observations", %{"observations" => [observation.("a.ex")]})
      assert_reply ref, :ok, %{"status" => "accepted", "observations" => 1}, 2_000

      assert ["a.ex"] = scope |> CodeMySpec.Files.list_files() |> Enum.map(& &1.path)
    end

    # The defect class this whole design exists to avoid: a harness that failed
    # to scan must not be able to report the same thing as an empty project.
    test "an empty manifest is refused rather than obeyed", %{channel: channel, scope: scope} do
      ref =
        push(channel, "observations", %{
          "observations" => [
            %{
              "path" => "lib/todo.ex",
              "role" => "implementation",
              "mtime" => "2026-07-28T10:00:00.000000Z",
              "size" => 10,
              "fingerprint" => "abc",
              "valid" => true,
              "validation_errors" => %{}
            }
          ]
        })

      assert_reply ref, :ok, _, 2_000

      ref = push(channel, "observations", %{"observations" => []})
      assert_reply ref, :error, %{"reason" => "empty_manifest"}, 2_000

      assert length(CodeMySpec.Files.list_files(scope)) == 1,
             "an empty manifest must not be able to wipe a project's files"
    end

    test "a role this server does not know is reported as skew, not written as nil",
         %{channel: channel, scope: scope} do
      ref =
        push(channel, "observations", %{
          "observations" => [
            %{
              "path" => "lib/todo.ex",
              "role" => "some_role_from_a_newer_harness",
              "mtime" => "2026-07-28T10:00:00.000000Z",
              "size" => 10,
              "fingerprint" => "abc",
              "valid" => true,
              "validation_errors" => %{}
            }
          ]
        })

      assert_reply ref, :error, %{"reason" => "invalid_manifest", "problems" => problems}, 2_000
      assert Enum.any?(problems, &String.contains?(&1, "some_role_from_a_newer_harness"))

      assert CodeMySpec.Files.list_files(scope) == [],
             "a manifest the server cannot understand must not be half-applied"
    end

    test "a whole-second mtime is refused rather than killing the channel",
         %{channel: channel, scope: scope} do
      ref =
        push(channel, "observations", %{
          "observations" => [
            %{
              "path" => "lib/todo.ex",
              "role" => "implementation",
              # No fractional part. Parses to a valid DateTime, and used to reach
              # `Files.upsert_files/2` and raise against a :utc_datetime_usec
              # column — inside the channel process, so the harness saw a dropped
              # connection and re-sent the same manifest forever.
              "mtime" => "2026-07-28T10:00:00Z",
              "size" => 10,
              "fingerprint" => "abc",
              "valid" => true,
              "validation_errors" => %{}
            }
          ]
        })

      assert_reply ref, :error, %{"reason" => "invalid_manifest", "problems" => problems}, 2_000
      assert Enum.any?(problems, &String.contains?(&1, "precision"))

      assert CodeMySpec.Files.list_files(scope) == [],
             "a refused manifest must not be half-applied"

      # The point of the fix. A reply is only the visible half — what mattered
      # was that the process answering it is still there, because a dead channel
      # is indistinguishable from a network drop and is what made this a loop.
      assert Process.alive?(channel.channel_pid),
             "the channel died refusing a manifest, so the harness will read this as a " <>
               "dropped connection, reconnect, re-send, and die again"

      ref =
        push(channel, "observations", %{
          "observations" => [
            %{
              "path" => "lib/todo.ex",
              "role" => "implementation",
              "mtime" => "2026-07-28T10:00:00.000000Z",
              "size" => 10,
              "fingerprint" => "abc",
              "valid" => true,
              "validation_errors" => %{}
            }
          ]
        })

      assert_reply ref, :ok, _summary, 2_000

      assert length(CodeMySpec.Files.list_files(scope)) == 1,
             "the same harness must be able to correct itself on the same connection"
    end
  end

  describe "module_name" do
    setup %{scope: scope, topic: topic} do
      # The main one, because only the main checkout may say what the project is
      # called. Every copy sends this on every sync, so ungated it was
      # last-writer-wins between checkouts that need not even be the same app —
      # see `HarnessProjectModuleNameTest`, which owns the gate itself. Here the
      # copy is made main so these keep testing the correction rather than
      # silently testing the refusal.
      {:ok, copy} = WorkingCopies.fetch(scope.active_working_copy_id)
      copy |> Ecto.Changeset.change(main: true) |> CodeMySpec.Repo.update!()

      {:ok, _reply, channel} = join_as(scope, topic)
      %{channel: channel}
    end

    # `mix.exs`'s own `app:` atom, camelized and relayed here on every sync,
    # is the fix for a project a server-side check has no real way to read
    # `mix.exs` from at all (see `CodeMySpec.Provisioning.Steps.app_path/1`)
    # — this is what keeps that fallback correct without a repeat onboarding
    # step. Sent CamelCase, matching `CmsHarness.Sync`'s own
    # `Macro.camelize/1`: `module_name` is validated as an Elixir module name,
    # and `app_path/1` un-derives this exact value back with
    # `Macro.underscore/1`.
    test "corrects a stale module_name", %{channel: channel, scope: scope} do
      ref = push(channel, "module_name", %{"module_name" => "MarketMySpec"})

      assert_reply ref, :ok, _reply, 2_000

      assert CodeMySpec.Projects.get_project_by_id(scope.active_project_id).module_name ==
               "MarketMySpec"
    end

    test "an already-correct module_name is left alone", %{
      channel: channel,
      scope: scope
    } do
      {:ok, project} =
        CodeMySpec.Projects.update_project(scope, scope.active_project, %{
          module_name: "MarketMySpec"
        })

      ref = push(channel, "module_name", %{"module_name" => "MarketMySpec"})

      assert_reply ref, :ok, _reply, 2_000
      assert CodeMySpec.Projects.get_project_by_id(project.id).updated_at == project.updated_at
    end

    test "an empty name is ignored rather than written", %{channel: channel, scope: scope} do
      ref = push(channel, "module_name", %{"module_name" => ""})

      assert_reply ref, :ok, _reply, 2_000

      assert CodeMySpec.Projects.get_project_by_id(scope.active_project_id).module_name ==
               scope.active_project.module_name
    end
  end

  describe "health_route_status" do
    setup %{scope: scope, topic: topic} do
      {:ok, _reply, channel} = join_as(scope, topic)
      %{channel: channel}
    end

    # Same self-healing shape as module_name, for a check `Files` sync cannot
    # answer at all (it records existence, never a body) — see
    # `CodeMySpec.Generators.health_route_finding/3`.
    test "corrects a stale status", %{channel: channel, scope: scope} do
      ref = push(channel, "health_route_status", %{"status" => "ok"})

      assert_reply ref, :ok, _reply, 2_000

      assert CodeMySpec.Projects.get_project_by_id(scope.active_project_id).health_route_status ==
               "ok"
    end

    test "an already-correct status is left alone", %{channel: channel, scope: scope} do
      {:ok, project} =
        CodeMySpec.Projects.update_project(scope, scope.active_project, %{
          health_route_status: "no_health_route"
        })

      ref = push(channel, "health_route_status", %{"status" => "no_health_route"})

      assert_reply ref, :ok, _reply, 2_000
      assert CodeMySpec.Projects.get_project_by_id(project.id).updated_at == project.updated_at
    end

    test "an unrecognised status is ignored rather than written", %{
      channel: channel,
      scope: scope
    } do
      ref = push(channel, "health_route_status", %{"status" => "not_a_real_status"})

      assert_reply ref, :ok, _reply, 2_000

      assert CodeMySpec.Projects.get_project_by_id(scope.active_project_id).health_route_status ==
               scope.active_project.health_route_status
    end
  end

  describe "hook decisions" do
    setup %{scope: scope, topic: topic} do
      {:ok, _reply, channel} =
        join_as(scope, topic)

      %{channel: channel}
    end

    test "a stop decision comes back over the channel", %{channel: channel} do
      ref =
        push(channel, "hook_decision", %{
          "hook" => "stop",
          "payload" => %{"session_id" => "s1", "cwd" => "/workspace/app"}
        })

      assert_reply ref, :ok, decision, 5_000
      assert is_map(decision)
    end

    # The server cannot know which port the harness serves on, and the rewritten
    # analysis curl only means anything on the agent's own machine. Refusing is
    # the only honest answer; pointing it somewhere plausible would produce a
    # command that runs and reports against the wrong process.
    test "pre-tool-use without the harness's port is refused, not guessed",
         %{channel: channel} do
      ref =
        push(channel, "hook_decision", %{
          "hook" => "pre-tool-use",
          "payload" => %{"tool_name" => "Bash", "tool_input" => %{"command" => "mix test"}}
        })

      assert_reply ref, :error, %{"reason" => "port_required"}, 5_000
    end

    test "an unknown hook says so", %{channel: channel} do
      ref = push(channel, "hook_decision", %{"hook" => "not-a-hook", "payload" => %{}})

      assert_reply ref, :error, %{"reason" => "unknown_hook: not-a-hook"}, 5_000
    end
  end

  # The gap this closed: the harness ran no analyzers, so `Stop.decide/2`
  # consulted persisted Problems and found none — from a set of facts nobody had
  # gathered. A stop hook answering `{}` looked identical whether the project was
  # clean or unexamined.
  #
  # These drive the whole loop from the channel: a stop asks for analysis, the
  # runs are opened and pushed, the result comes back as diagnostics, Problems
  # land, and the next stop blocks. `analysis_mode: :inline` is irrelevant here —
  # a remote run never touches the local queue.
  describe "analysis" do
    setup %{scope: scope, topic: topic} do
      {:ok, _reply, channel} = join_as(scope, topic)
      %{channel: channel}
    end

    alias CodeMySpec.Analysis
    alias CodeMySpec.Problems

    defp compiler_result(run_id, diagnostics) do
      %{
        "run_id" => run_id,
        "source" => "compiler",
        "status" => "ok",
        "result" => %{"exit_status" => 1, "diagnostics" => diagnostics}
      }
    end

    defp broken_file_diagnostic do
      %{
        "file" => "lib/demo/broken.ex",
        "line" => 4,
        "severity" => "error",
        "message" => "** (SyntaxError) unexpected reserved word: end"
      }
    end

    # The agent's own `mix test`, rewritten into this by the PreToolUse hook.
    #
    # The reply is deferred: `await_run/4` takes as long as the suite does, and
    # answering inline would hold the channel for it — starving the stop
    # decision behind it, which is the defect the manifest reconcile already
    # had. So the request must come back as a dispatch, not as a reply.
    test "an agent's run is dispatched and left unanswered until it finishes",
         %{channel: channel} do
      ref =
        push(channel, "analysis_run", %{"source" => "exunit", "args" => ["test/foo_test.exs"]})

      assert_push "run_analysis", %{"runs" => runs}, 5_000
      assert [%{"source" => "exunit", "args" => ["test/foo_test.exs"]}] = runs

      refute_reply ref, :ok, _payload, 200
    end

    # The run row is opened before dispatch, and that is what makes the request
    # recoverable: if the harness never answers, the row is failed when its
    # channel closes. A fire-and-forget push would leave nothing behind.
    test "an agent's run opens a row the harness can be held to", %{channel: channel} do
      ref = push(channel, "analysis_run", %{"source" => "credo", "args" => []})

      assert_push "run_analysis", %{"runs" => [run]}, 5_000
      assert is_integer(run["run_id"])

      refute_reply ref, :ok, _payload, 200
    end

    # A harness that takes the run and never comes back. The agent has to be
    # told, and told as a failure: `curl` exits 0 on an empty body, so silence
    # here would reach the agent as a suite that ran and passed.
    test "a run the harness never answers fails rather than going quiet",
         %{channel: channel} do
      ref = push(channel, "analysis_run", %{"source" => "credo", "args" => []})

      assert_push "run_analysis", %{"runs" => [_run]}, 5_000

      assert_reply ref, :error, %{"reason" => reason}, 5_000
      assert reason =~ "harness_never_answered"
    end

    test "a stop asks the harness to run the compiler", %{channel: channel} do
      ref = push(channel, "hook_decision", %{"hook" => "stop", "payload" => %{}})
      assert_reply ref, :ok, _decision, 5_000

      assert_push "run_analysis", %{"runs" => runs}, 5_000

      assert Enum.any?(runs, &(&1["source"] == "compiler")),
             "the compiler is the cheapest signal and every other source short-circuits " <>
               "on its errors, so it is always requested"

      assert Enum.all?(runs, &is_integer(&1["run_id"])),
             "the run row is opened here so the request is recoverable — a push with no " <>
               "row would leave no trace that anything was ever asked for"
    end

    test "a stop while the harness is still running one says so, rather than reporting clean",
         %{channel: channel} do
      ref = push(channel, "hook_decision", %{"hook" => "stop", "payload" => %{}})
      assert_reply ref, :ok, _first, 5_000
      assert_push "run_analysis", %{"runs" => _}, 5_000

      ref = push(channel, "hook_decision", %{"hook" => "stop", "payload" => %{}})
      assert_reply ref, :ok, decision, 5_000

      assert decision["systemMessage"] =~ "analysis running",
             "\"I have not looked yet\" has to be a different answer from \"nothing blocks\""
    end

    test "diagnostics from the harness become Problems", %{channel: channel, scope: scope} do
      ref = push(channel, "hook_decision", %{"hook" => "stop", "payload" => %{}})
      assert_reply ref, :ok, _decision, 5_000
      assert_push "run_analysis", %{"runs" => runs}, 5_000

      run_id = runs |> Enum.find(&(&1["source"] == "compiler")) |> Map.fetch!("run_id")

      ref = push(channel, "analysis_result", compiler_result(run_id, [broken_file_diagnostic()]))
      assert_reply ref, :ok, %{"status" => "completed"}, 5_000

      assert [problem] = Problems.list_project_problems(scope, source: "compiler")
      assert problem.severity == :error
      assert problem.file_path == "lib/demo/broken.ex"
    end

    # The acceptance test, in process. The wire version of it is the e2e run.
    test "a project whose code will not compile has its next stop BLOCKED",
         %{channel: channel, scope: scope} do
      ref = push(channel, "hook_decision", %{"hook" => "stop", "payload" => %{}})
      assert_reply ref, :ok, first, 5_000

      refute first["decision"] == "block",
             "nothing has been looked at yet, so this stop is allowed — but labelled"

      assert_push "run_analysis", %{"runs" => runs}, 5_000
      run_id = runs |> Enum.find(&(&1["source"] == "compiler")) |> Map.fetch!("run_id")

      ref = push(channel, "analysis_result", compiler_result(run_id, [broken_file_diagnostic()]))
      assert_reply ref, :ok, _recorded, 5_000

      # Drain whatever the reconcile enqueued next, so the stop below is
      # decided from the Problems rather than from a run still in flight.
      Analysis.fail_in_flight(scope, :test_drain)

      ref = push(channel, "hook_decision", %{"hook" => "stop", "payload" => %{}})
      assert_reply ref, :ok, decision, 5_000

      assert decision["decision"] == "block", """
      A working copy that does not compile got a green light.

      This is the defect the analyzer path was built for: before it, the harness
      ran nothing, so the stop hook consulted persisted Problems, found none, and
      answered `{}` — from a set of facts nobody had gathered.
      """

      assert decision["reason"] =~ "broken.ex"
    end

    test "a run the harness could not do fails rather than completing empty",
         %{channel: channel, scope: scope} do
      ref = push(channel, "hook_decision", %{"hook" => "stop", "payload" => %{}})
      assert_reply ref, :ok, _decision, 5_000
      assert_push "run_analysis", %{"runs" => runs}, 5_000

      run_id = runs |> Enum.find(&(&1["source"] == "compiler")) |> Map.fetch!("run_id")

      ref =
        push(channel, "analysis_result", %{
          "run_id" => run_id,
          "source" => "compiler",
          "status" => "error",
          "error" => "analyzer timed out after 1800000ms"
        })

      assert_reply ref, :error, %{"reason" => reason}, 5_000
      assert reason =~ "timed out"

      refute Analysis.fresh?(scope, "compiler"), """
      A failed run must never satisfy freshness. If it did, an analyzer that
      could not run would make the source look current and stop re-enqueueing —
      "nobody looked" recorded as "looked, and it is clean".
      """
    end

    test "a result for a run this server is not tracking is refused", %{channel: channel} do
      ref =
        push(channel, "analysis_result", compiler_result(999_999, [broken_file_diagnostic()]))

      assert_reply ref, :error, %{"reason" => "unknown_run"}, 5_000
    end

    # How `unknown_run` was actually being produced, end to end.
    #
    # `SubagentStop` matched `{:error, reason}` while `Validation.validate_stop/3`
    # returns `{:error, reason, blocking_key}`, so a sub-agent stopping with
    # anything to block on raised `CaseClauseError` *inside the channel process*.
    # The channel died, `terminate/2` read that as the harness going away and
    # failed every run it had open — while the harness, which never went
    # anywhere, was still running them. Those analyzers finished, sent their
    # results, and were told `unknown_run` because the rows were no longer
    # `:running`.
    #
    # Self-sustaining: nothing could refresh, so the stale finding that crashed
    # the stop was still there to crash the next one. Observed as seven channel
    # closes and eleven rejected results in one evening.
    test "a sub-agent stopping with problems blocks, rather than killing the channel",
         %{channel: channel, scope: scope} do
      Process.flag(:trap_exit, true)

      # A compiler error blocks unconditionally — no mode, no changed-file
      # scoping to arrange. What matters is only that something blocks.
      problem_fixture(scope, %{
        source: "compiler",
        severity: :error,
        file_path: "lib/demo/broken.ex"
      })

      # And that it is *this sub-agent's*, which used to be true by default and
      # is not any more.
      #
      # A session with no recorded edits now has every attributable finding
      # demoted to advisory — a session that wrote nothing cannot own one
      # (`76008385`). This test had no edits, so its compiler error stopped
      # blocking and the assertion below failed.
      #
      # Recording the edit rather than relaxing the assertion, because "block"
      # is not what this test is about: it is the vehicle for reaching the
      # `{:error, reason, blocking_key}` clause that `SubagentStop` used to
      # crash on. Accepting "allow" would leave the test passing while the crash
      # path it exists to cover went unexercised.
      #
      # The File row is needed as well as the edit: `verify_against_ledger/3`
      # answers `nil` for recorded paths that join no file in the project, and
      # `nil` blocks everything — which would also make this pass, for the wrong
      # reason and via the wrong branch.
      {:ok, _} =
        Files.upsert_file_metadata(scope, %{
          path: "lib/demo/broken.ex",
          role: :implementation,
          mtime: DateTime.utc_now(),
          size: 1,
          fingerprint: "subagent-stop-blocks"
        })

      :ok = FileEdits.track_edit("s1", "lib/demo/broken.ex", "a1")

      ref =
        push(channel, "hook_decision", %{
          "hook" => "subagent-stop",
          "payload" => %{"session_id" => "s1", "agent_id" => "a1"}
        })

      assert_reply ref, :ok, decision, 5_000

      assert decision["decision"] == "block",
             "the sub-agent has an unresolved compiler error in a file it edited, and must be told so"

      assert decision["reason"] =~ "broken.ex"

      # The runs this very stop enqueued. The harness is still holding them, so
      # nothing here may close them — closing them is what made their results
      # unrecordable.
      assert Analysis.runs_in_flight?(scope), """
      The stop swept the runs the harness is still working on.

      They can only be closed when their executor provably cannot answer. A
      decision made *on* this channel is not that: the harness is on the other
      end of it, still running the analyzers, and every result it sends back
      will now be refused as `unknown_run`.
      """

      assert Process.alive?(channel.channel_pid),
             "a hook that cannot decide must answer, not crash — the channel is the harness's " <>
               "only route to this server, and it takes the run ledger down with it"
    end
  end

  # A run left `:running` makes `in_flight/1` report analysis pending on every
  # later stop, which allows the stop with a note that results apply next time —
  # on a next time that never comes. The queue that was going to answer those
  # runs died with the harness that held it, so a hard kill is the case that
  # matters: `terminate/2` does not get to run, and the cleanup has to happen at
  # the next join instead.
  describe "runs a departed harness left open" do
    alias CodeMySpec.Analysis

    setup do
      Process.flag(:trap_exit, true)
      :ok
    end

    test "are closed when the next harness joins", %{scope: scope, topic: topic} do
      {:ok, %{working_copy_id: id}, channel} = join_with(scope, topic, nil)

      # "In flight" is a question about a working copy now — the runs belong to
      # the harness whose queue was going to answer them, and a scope naming a
      # different one is asking about a different machine.
      served = %{scope | active_working_copy_id: id}

      ref = push(channel, "hook_decision", %{"hook" => "stop", "payload" => %{}})
      assert_reply ref, :ok, _decision, 5_000
      assert_push "run_analysis", %{"runs" => _}, 5_000

      assert Analysis.runs_in_flight?(served)

      down = Process.monitor(channel.channel_pid)
      Process.exit(channel.channel_pid, :kill)
      assert_receive {:DOWN, ^down, :process, _, _}, 2_000

      # The same working copy coming back, which is what a restarted harness is:
      # it presents the id it wrote down.
      assert eventually(fn -> match?({:ok, _, _}, join_with(scope, topic, id)) end)

      refute Analysis.runs_in_flight?(served),
             "an open run whose executor is gone makes every later stop report analysis " <>
               "pending — an allow, forever"
    end

    # The other half. Sweeping on join is right for a harness that restarted and
    # took its queue with it; it is wrong for one whose socket dropped, because
    # the analyzers are OS processes on its machine and a closed socket does not
    # touch them. They finish, report, and are refused for a run that is no
    # longer `:running` — which is `unknown_run`, and how a stop hook ends up
    # frozen on findings nothing can refresh.
    #
    # The harness is the only thing that knows, so it says so on join.
    test "are spared when the returning harness still holds them", %{
      scope: scope,
      topic: topic
    } do
      {:ok, %{working_copy_id: id}, channel} = join_with(scope, topic, nil)
      served = %{scope | active_working_copy_id: id}

      ref = push(channel, "hook_decision", %{"hook" => "stop", "payload" => %{}})
      assert_reply ref, :ok, _decision, 5_000
      assert_push "run_analysis", %{"runs" => _}, 5_000
      assert Analysis.runs_in_flight?(served)

      open_ids = open_run_ids(served)
      assert open_ids != []

      down = Process.monitor(channel.channel_pid)
      Process.exit(channel.channel_pid, :kill)
      assert_receive {:DOWN, ^down, :process, _, _}, 2_000

      assert eventually(fn ->
               match?({:ok, _, _}, join_claiming(scope, topic, id, open_ids))
             end)

      assert Analysis.runs_in_flight?(served),
             "a run the harness is still executing must survive its socket dropping, " <>
               "or the result it is about to send is refused as unknown_run"
    end

    defp join_claiming(scope, topic, working_copy_id, run_ids) do
      scope
      |> harness_socket([])
      |> subscribe_and_join(HarnessProjectChannel, topic, %{
        "label" => @label,
        "harness_id" => working_copy_id,
        "active_runs" => run_ids
      })
    end

    defp open_run_ids(scope) do
      import Ecto.Query

      CodeMySpec.Analysis.Run
      |> where([r], r.project_id == ^scope.active_project_id and r.status == :running)
      |> select([r], r.id)
      |> CodeMySpec.Repo.all()
    end
  end

  # This is the test that would have caught the defect it was written for.
  #
  # The harness pushed `hook_decision` for weeks of work while this server had no
  # clause for it. The old catch-all returned `{:noreply, socket}`, so the push
  # got no reply at all and the harness sat out its full timeout on every hook —
  # on the critical path of every agent turn. Both suites stayed green: this one
  # did not know the event existed, and the harness's tests run against a fake
  # server that did implement it.
  #
  # A fake is the right way to test the harness in isolation. What it cannot do
  # is notice that it has drifted from the real thing, so that has to be asserted
  # somewhere, and this is the somewhere.
  describe "the wire contract" do
    setup %{scope: scope, topic: topic} do
      {:ok, _reply, channel} =
        join_as(scope, topic)

      %{channel: channel}
    end

    # Keep in step with the events CmsHarness pushes — see
    # `CmsHarness.Project.ChannelClient` and `CmsHarnessTest.FakeServer`.
    @harness_events ~w(read_model observations hook_decision analysis_result)

    test "every event the harness sends is one this server implements", %{channel: channel} do
      for event <- @harness_events do
        ref =
          push(channel, event, %{
            "observations" => [],
            "hook" => "stop",
            "payload" => %{},
            "run_id" => 0,
            "source" => "compiler"
          })

        assert_receive %Phoenix.Socket.Reply{ref: ^ref, payload: payload}, 5_000, """
        The harness pushes #{inspect(event)} and this server never replied to it.

        A push with no reply is indistinguishable from a slow server: the harness
        waits out its whole decision timeout and then fails closed.
        """

        # Not merely "a reply came back" — the catch-all replies too, and a test
        # satisfied by that would pass for an event nobody implemented, which is
        # the exact hole it exists to close.
        refute payload["reason"] == "unknown_event", """
        #{inspect(event)} reached the catch-all: the harness sends it and this
        server has no clause for it. Add a handle_in clause, or stop sending it.
        """
      end
    end

    test "an event neither side knows is refused rather than swallowed",
         %{channel: channel} do
      ref = push(channel, "some_event_from_a_newer_harness", %{})

      assert_reply ref, :error, %{"reason" => "unknown_event"}, 5_000
    end
  end

  describe "the channel's lifetime is the lease" do
    # The channel is linked to the test process, so its death would take the
    # test with it — and its death is the thing under test.
    setup do
      Process.flag(:trap_exit, true)
      :ok
    end

    test "leaving frees the project for the next harness", %{scope: scope, topic: topic} do
      {:ok, _reply, first} =
        join_as(scope, topic)

      ref = Process.monitor(first.channel_pid)
      leave(first)
      assert_receive {:DOWN, ^ref, :process, _, _}, 2_000

      assert eventually(fn ->
               match?(
                 {:ok, _, _},
                 join_as(scope, topic)
               )
             end),
             "a departed harness must not keep holding the project"
    end

    test "a killed channel frees the project — no release, no expiry",
         %{scope: scope, topic: topic} do
      {:ok, _reply, first} =
        join_as(scope, topic)

      # The case the design exists for: nothing gets to run on the way out, the
      # way it would if the container were killed or the network dropped.
      ref = Process.monitor(first.channel_pid)
      Process.exit(first.channel_pid, :kill)
      assert_receive {:DOWN, ^ref, :process, _, _}, 2_000

      assert eventually(fn ->
               match?(
                 {:ok, _, _},
                 join_as(scope, topic)
               )
             end),
             "a killed harness must not hold a project until some deadline passes"
    end
  end

  # Postgres releases the lock as it reaps the closed connection — prompt, but
  # not synchronous with the channel process dying.
  defp eventually(fun, attempts \\ 40) do
    Enum.reduce_while(1..attempts, false, fn _, _ -> poll(fun.()) end)
  end

  # A disconnect fails every in-flight run for the working copy, so why it
  # happened is the most useful thing the server knows — and it was the one
  # thing it discarded. The harness cannot supply it: a crashed channel sends
  # `phx_error` with no payload, so the far side only ever logs
  # `closed: {:error, %{}}`.
  #
  # Asserting the log rather than the sweep on purpose. The sweep already had a
  # line; what was missing was the cause, and seven crashes in an evening read
  # as seven network drops because of it.
  describe "a channel that dies says why" do
    # The channel is linked to the test process and its death is the subject.
    setup do
      Process.flag(:trap_exit, true)
      :ok
    end

    # `terminate/2` is called directly rather than by killing the process.
    # `Process.exit/2` on a channel — which does not trap exits — skips
    # `terminate/2` altogether, so a test that kills it proves nothing about
    # what the callback logs. The callback is public and the logging is the
    # subject.
    test "an abnormal exit is logged at error with its reason", %{scope: scope, topic: topic} do
      {:ok, _reply, channel} = join_as(scope, topic)
      socket = :sys.get_state(channel.channel_pid)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          HarnessProjectChannel.terminate({:badmatch, :a_three_tuple}, socket)
        end)

      assert log =~ "channel DIED"

      assert log =~ "a_three_tuple",
             "the reason is the whole point — without it a crash and a network " <>
               "drop are the same line, which is how seven crashes read as seven drops"
    end

    test "a clean leave is not alarming", %{scope: scope, topic: topic} do
      {:ok, _reply, channel} = join_as(scope, topic)
      ref = Process.monitor(channel.channel_pid)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          Phoenix.ChannelTest.leave(channel)
          assert_receive {:DOWN, ^ref, :process, _, _}, 5_000
        end)

      refute log =~ "channel DIED"
    end

    # `:peer_closed` and a stale channel registration present identically from
    # the addressee's side — both drop channels and fail tool calls with a
    # transport error — and neither project's own log named which one happened.
    # Two sessions independently guessed wrong, in opposite directions, on the
    # same incident (225860ce). The instance id is the signature: every other
    # project on the same harness process died at the same moment too.
    test "names the harness instance behind the channel, so the collateral is greppable", %{
      scope: scope,
      topic: topic
    } do
      {:ok, _reply, channel} =
        scope
        |> harness_socket([])
        |> subscribe_and_join(HarnessProjectChannel, topic, %{
          "label" => @label,
          "harness_id" => scope.active_working_copy_id,
          "device" => %{"id" => device_fixture(scope).id},
          "instance" => "test-instance-42"
        })

      socket = :sys.get_state(channel.channel_pid)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          HarnessProjectChannel.terminate(:peer_closed, socket)
        end)

      assert log =~ "instance=test-instance-42",
             "the instance id is what lets a reader tell 'my registration is stale' " <>
               "from 'the harness died' — grepping it across server.log shows every " <>
               "other project the same process was serving"

      assert log =~ "every other project on it dropped at the same moment"
    end

    test "says nothing about an instance it was never told", %{scope: scope, topic: topic} do
      {:ok, _reply, channel} = join_as(scope, topic)
      socket = :sys.get_state(channel.channel_pid)

      log =
        ExUnit.CaptureLog.capture_log(fn ->
          HarnessProjectChannel.terminate(:peer_closed, socket)
        end)

      refute log =~ "instance=",
             "a harness that never announced an instance has none to name — " <>
               "inventing one would be worse than the silence it replaces"
    end
  end

  defp poll(true), do: {:halt, true}

  defp poll(_false) do
    Process.sleep(50)
    {:cont, false}
  end
end
