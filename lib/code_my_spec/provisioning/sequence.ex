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

  @type step :: %{
          key: atom(),
          label: String.t(),
          option: atom() | nil,
          why: String.t()
        }

  @sequence [
    %{
      key: :repository,
      label: "Repository",
      option: nil,
      why: "the remote CI publishes from and the harness pushes to"
    },
    %{key: :server, label: "Server", option: nil, why: "the box both environments start on"},
    %{
      key: :secrets,
      label: "Secrets",
      option: nil,
      why: "one age key per environment, so UAT's key cannot open production's"
    },
    %{
      key: :domain,
      label: "Domain",
      option: :domain,
      why: "the name everything else is reached by"
    },
    %{key: :dns, label: "DNS records", option: :domain, why: "points the name at the server"},
    %{key: :deploy, label: "Deploy", option: nil, why: "the app running on the server"},
    %{
      key: :tls,
      label: "Certificate",
      option: :domain,
      why: "the proxy issues it on first boot, so it follows the deploy"
    },
    %{
      key: :email,
      label: "Outbound email",
      option: :email,
      why: "sending domain verified before anything sends"
    },
    %{
      key: :inbound,
      label: "Inbound email",
      option: :inbound,
      why: "apex MX, which outbound deliberately does not touch"
    },
    %{key: :storage, label: "Object storage", option: :storage, why: "buckets for files"},
    %{
      key: :backups,
      label: "Backups",
      option: :backups,
      why: "scheduled dumps, proven by a restore"
    },
    %{
      key: :content,
      label: "Content publishing",
      option: :content,
      why: "proven by a post rendering on the deployed site"
    },
    %{
      key: :widget,
      label: "Feedback widget",
      option: :widget,
      why: "proven by a message from the deployed site"
    },
    %{
      key: :callback_credential,
      label: "Callback credential",
      option: nil,
      why: "how the deployed app talks back without a long-lived key"
    },
    %{
      key: :monitoring,
      label: "Uptime monitoring",
      option: :monitoring,
      why: "notices when the site stops answering"
    }
  ]

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
      [:repository, :server, :secrets, :deploy, :callback_credential]
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
  Position of a step in the full sequence, for ordering persisted rows.

  Positions come from the full sequence rather than the filtered one, so
  turning an option on later does not renumber the steps already run.
  """
  @spec position(atom()) :: non_neg_integer() | nil
  def position(key), do: Enum.find_index(@sequence, &(&1.key == key))
end
