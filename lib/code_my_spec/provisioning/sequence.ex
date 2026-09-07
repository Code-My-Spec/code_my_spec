defmodule CodeMySpec.Provisioning.Sequence do
  @moduledoc """
  The ordered setup sequence, and which steps a project's options include.

  Pure — no database, no provider calls. The sequence is a fact about how
  setup is shaped, so it can be shown before anything runs (criterion 7959)
  and reasoned about without touching a provider.

  ## Ordering is a dependency claim, not a preference

  Each step's position encodes what must exist before it. `repository` is
  first because CI publishes the image the deploy pulls, so a deploy with no
  remote has nothing to build from (story 985, criterion 8182). `deploy`
  precedes `content` and `widget` because both are proven against the running
  site.

  `secrets` precedes `server` because the server step *writes* one. It serves
  the database and puts `DATABASE_URL` into the environment's encrypted env
  (`serve_database/4`), so the age key that opens that file has to exist first.
  With `server` ahead of it, a project whose encrypted env could not be opened —
  a fresh checkout, a rotated key, a file committed by somebody whose key is
  elsewhere — died in the server step on a raw sops dump, one position before
  the step that knows how to handle exactly that and says so in words
  ("written to a key that no longer exists — discarding"). Nothing in `secrets`
  needs a box: it mints keys, writes `.sops.yaml`, and seeds the two secrets the
  app boots with.

  `tls` follows *both* `dns` and `deploy`, because issuance has two
  preconditions and naming only one of them deadlocked cold setup. The name
  must resolve to the server, which is `dns`; and kamal-proxy must be
  answering on 80 to satisfy the HTTP-01 challenge, which is `deploy`. With
  `tls` sequenced between them it verified a certificate only `deploy` could
  cause to exist, errored on every new project, and halted the run before the
  step that would have fixed it. Every step passed its own criterion — the
  ordering they composed into could not run, because nothing exercised the
  full sequence against a cold server.

  Reordering this list changes what setup depends on, which is why it is one
  list read top to bottom rather than per-step `after:` declarations that
  would let a cycle in unnoticed.

  ## Options subtract, never reorder

  An option Sam turned off removes its steps and leaves the rest in the same
  order (criterion 7968). A disabled step is absent from the plan, not present
  and skipped — a skipped step still reads as part of the run, and Sam asked
  for it not to be.
  """

  @type scope :: :project | :environment

  @type step :: %{
          key: atom(),
          label: String.t(),
          option: atom() | nil,
          why: String.t(),
          scope: scope()
        }

  @sequence [
    %{
      key: :repository,
      label: "Repository",
      option: nil,
      why: "the remote CI publishes from and the harness pushes to",
      scope: :project
    },
    %{
      key: :secrets,
      label: "Secrets",
      option: nil,
      why: "one age key per environment, so UAT's key cannot open production's",
      scope: :environment
    },
    %{
      key: :server,
      label: "Server",
      option: nil,
      why: "the box both environments start on",
      scope: :project
    },
    %{
      key: :domain,
      label: "Domain",
      option: :domain,
      why: "the name everything else is reached by",
      scope: :project
    },
    %{
      key: :dns,
      label: "DNS records",
      option: :domain,
      why: "points the name at the server",
      scope: :project
    },
    %{
      key: :deploy,
      label: "Deploy",
      option: nil,
      why: "the app running on the server",
      scope: :environment
    },
    %{
      key: :tls,
      label: "Certificate",
      option: :domain,
      why: "the proxy issues it on first boot, so it follows the deploy",
      scope: :environment
    },
    %{
      key: :email,
      label: "Outbound email",
      option: :email,
      why: "sending domain verified before anything sends",
      scope: :project
    },
    %{
      key: :inbound,
      label: "Inbound email",
      option: :inbound,
      why: "apex MX, which outbound deliberately does not touch",
      scope: :project
    },
    %{
      key: :storage,
      label: "Object storage",
      option: :storage,
      why: "buckets for files",
      scope: :environment
    },
    %{
      key: :backups,
      label: "Backups",
      option: :backups,
      why: "scheduled dumps, proven by a restore",
      scope: :environment
    },
    %{
      key: :content,
      label: "Content publishing",
      option: :content,
      why: "proven by a post rendering on the deployed site",
      scope: :environment
    },
    %{
      key: :widget,
      label: "Feedback widget",
      option: :widget,
      why: "proven by a message from the deployed site",
      scope: :environment
    },
    %{
      key: :callback_credential,
      label: "Callback credential",
      option: nil,
      why: "how the deployed app talks back without a long-lived key",
      scope: :environment
    }
  ]

  # Uptime monitoring is not a step, because setup does not do it.
  #
  # It was `UptimeRobot.ensure_monitors/3`, which needs an account, an API key
  # and a notification target that only a person can supply — so the step
  # paused on every run and setup could never report complete. The choice was
  # between carrying a third-party dependency in the path of "did my site go
  # down" or building the monitoring ourselves, and neither is worth it right
  # now.
  #
  # Removed rather than left pausing. A step that cannot finish is worse than
  # an absent one: it makes every completed setup look unfinished, and it
  # claims a capability nothing delivers. Criterion 1968 is narrowed to backups
  # to match — the honest position is that setup does not leave a monitor
  # watching, not that it does and cannot prove it.
  #
  # `cms_new` still generates `/_cms/verify/always-failing`, which is down by
  # construction, so whatever monitoring is eventually pointed at these
  # applications can be proven to notice something.

  @doc "Every step, in order, regardless of options."
  @spec all() :: [step()]
  def all, do: @sequence

  @doc "Every step key, in order."
  @spec keys() :: [atom()]
  def keys, do: Enum.map(@sequence, & &1.key)

  @doc """
  The steps a project's enabled options include, in order.

  `enabled` is the set of option atoms that are on. A step with no `:option`
  is unconditional — the repository, the server, its secrets, the deploy and
  the callback credential are what "set up" means.

  ## Examples

      iex> CodeMySpec.Provisioning.Sequence.for_options([]) |> Enum.map(& &1.key)
      [:repository, :secrets, :server, :deploy, :callback_credential]
  """
  @spec for_options([atom()] | MapSet.t()) :: [step()]
  def for_options(enabled) do
    on = MapSet.new(enabled)
    Enum.filter(@sequence, fn step -> is_nil(step.option) or MapSet.member?(on, step.option) end)
  end

  @doc "Look up one step by key."
  @spec fetch(atom()) :: {:ok, step()} | :error
  def fetch(key) do
    case Enum.find(@sequence, &(&1.key == key)) do
      nil -> :error
      step -> {:ok, step}
    end
  end

  @doc """
  Whether a step's state is one row for the whole project or one row per
  environment.

  Defaults to `:project` for a key this sequence does not know — `:monitoring`
  is still a valid `Step.key()` (removed from the sequence, never from the
  enum) and an old row of that kind casts as project-wide rather than
  rejecting.
  """
  @spec scope(atom()) :: scope()
  def scope(key) do
    case fetch(key) do
      {:ok, step} -> step.scope
      :error -> :project
    end
  end

  @doc """
  Position of a step in the full sequence, for ordering persisted rows.

  Positions come from the full sequence rather than the filtered one, so
  turning an option on later does not renumber the steps already run.
  """
  @spec position(atom()) :: non_neg_integer() | nil
  def position(key), do: Enum.find_index(@sequence, &(&1.key == key))
end
