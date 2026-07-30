defmodule CodeMySpec.Provisioning.StepTest do
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Provisioning.Step
  alias CodeMySpec.Repo

  setup do
    %{scope: full_scope_fixture()}
  end

  defp attrs(scope, overrides \\ %{}) do
    Map.merge(
      %{key: :server, state: :not_started, position: 0, project_id: scope.active_project_id},
      overrides
    )
  end

  describe "the state vocabulary" do
    test "covers exactly the five states story 963 distinguishes" do
      assert Step.states() == [:not_started, :running, :done, :errored, :paused]
    end

    test "a step starts not_started without being told to" do
      assert %Step{state: :not_started} = %Step{}
    end

    test "an unknown state is rejected rather than stored", %{scope: scope} do
      changeset = Step.changeset(%Step{}, attrs(scope, %{state: :in_progress}))

      refute changeset.valid?
      assert %{state: [_ | _]} = errors_on(changeset)
    end
  end

  describe "the step sequence" do
    test "names every step the spex drive" do
      # Taken from the data-step attributes across stories 963-974. A key the
      # page renders but the schema cannot store would fail at insert time,
      # far from the template that named it.
      for key <- ~w(server domain dns tls deploy email inbound storage backups
                    content widget callback_credential monitoring)a do
        assert key in Step.keys(), "step key #{key} is driven by the spex but not storable"
      end
    end

    test "an unknown key is rejected", %{scope: scope} do
      changeset = Step.changeset(%Step{}, attrs(scope, %{key: :provision_everything}))

      refute changeset.valid?
      assert %{key: [_ | _]} = errors_on(changeset)
    end

    test "one row per project per step", %{scope: scope} do
      assert {:ok, _} = %Step{} |> Step.changeset(attrs(scope)) |> Repo.insert()

      assert {:error, changeset} = %Step{} |> Step.changeset(attrs(scope)) |> Repo.insert()
      assert %{project_id: [_ | _]} = errors_on(changeset)
    end
  end

  describe "a paused step" do
    # Criterion 7967 renders data-test='paused-instructions' from this field.
    # Pausing without it tells Sam to go do something without saying what.
    test "must say what Sam has to do elsewhere", %{scope: scope} do
      changeset = Step.changeset(%Step{}, attrs(scope, %{key: :domain, state: :paused}))

      refute changeset.valid?
      assert %{paused_instructions: [_ | _]} = errors_on(changeset)
    end

    test "is valid once it does", %{scope: scope} do
      changeset =
        Step.changeset(
          %Step{},
          attrs(scope, %{
            key: :domain,
            state: :paused,
            paused_instructions: "Register example.com at your registrar, then resume."
          })
        )

      assert changeset.valid?
    end
  end

  describe "an errored step" do
    # Criterion 7962: the escalation must name what was attempted and carry
    # the provider's own message. Storing neither yields the generic
    # "domain step failed" that criterion exists to prevent.
    test "must record the attempt and the provider's own error", %{scope: scope} do
      changeset = Step.changeset(%Step{}, attrs(scope, %{key: :domain, state: :errored}))

      refute changeset.valid?
      errors = errors_on(changeset)
      assert %{attempted: [_ | _]} = errors
      assert %{provider_error: [_ | _]} = errors
    end

    test "keeps the provider's text verbatim rather than summarising", %{scope: scope} do
      verbatim =
        "Authentication error: the API token does not have Registrar write permission"

      {:ok, step} =
        %Step{}
        |> Step.changeset(
          attrs(scope, %{
            key: :domain,
            state: :errored,
            attempted: "register example.com via Cloudflare Registrar",
            provider_error: verbatim
          })
        )
        |> Repo.insert()

      assert Repo.reload(step).provider_error == verbatim
    end
  end

  describe "provisioned resources" do
    test "record what the thing is and where Sam can find it", %{scope: scope} do
      {:ok, step} =
        %Step{}
        |> Step.changeset(
          attrs(scope, %{
            state: :done,
            resources: [
              %{kind: "server", location: "hetzner/nbg1/cms-prod", identifier: "12345"}
            ]
          })
        )
        |> Repo.insert()

      assert [resource] = Repo.reload(step).resources
      assert resource.kind == "server"
      assert resource.location == "hetzner/nbg1/cms-prod"
    end

    # Criterion 7969 asserts every listed resource names where it lives, so a
    # resource without a location is not worth recording.
    test "a resource with no location is rejected", %{scope: scope} do
      changeset =
        Step.changeset(%Step{}, attrs(scope, %{resources: [%{kind: "server"}]}))

      refute changeset.valid?
    end

    test "re-running a step replaces its resources rather than appending", %{scope: scope} do
      {:ok, step} =
        %Step{}
        |> Step.changeset(
          attrs(scope, %{resources: [%{kind: "server", location: "hetzner/nbg1/old"}]})
        )
        |> Repo.insert()

      {:ok, step} =
        step
        |> Step.changeset(%{resources: [%{kind: "server", location: "hetzner/nbg1/new"}]})
        |> Repo.update()

      assert [%{location: "hetzner/nbg1/new"}] = Repo.reload(step).resources
    end

    # The column carries no default, deliberately — defaults live on the
    # schema. This pins that a row written without resources still loads as
    # an empty list rather than nil, which every caller mapping over it
    # depends on.
    test "a row with no resources loads as an empty list", %{scope: scope} do
      {:ok, step} = %Step{} |> Step.changeset(attrs(scope)) |> Repo.insert()

      assert Repo.reload(step).resources == []
    end
  end

  describe "position" do
    test "is required — the sequence is ordered", %{scope: scope} do
      changeset = Step.changeset(%Step{}, Map.delete(attrs(scope), :position))

      refute changeset.valid?
      assert %{position: [_ | _]} = errors_on(changeset)
    end

    test "cannot be negative", %{scope: scope} do
      changeset = Step.changeset(%Step{}, attrs(scope, %{position: -1}))

      refute changeset.valid?
    end
  end
end
