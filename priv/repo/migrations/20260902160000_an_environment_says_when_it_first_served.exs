defmodule CodeMySpec.Repo.Migrations.AnEnvironmentSaysWhenItFirstServed do
  use Ecto.Migration

  # `Deploy.run/3` needed to know whether an environment has ever had a
  # successful deploy, to decide whether a failing health check is
  # protecting something live or refusing a genuine first deploy for no
  # reason. It used to infer this from whether kamal had ever written
  # `env/roles/<role>.env` on the host — a side effect of a container
  # *attempting* to boot, not of one succeeding, and never cleaned up when
  # that boot crashes or gets rolled back. A crashed first attempt leaves
  # the file behind, and every later run then health-checks a "previous
  # version" that was never actually live, refusing to swap forever.
  #
  # This is the platform's own answer instead: set once, the first time a
  # deploy for this environment actually swaps, and never touched again —
  # not inferred from anything an external tool's side effect can leave
  # lying around.
  def change do
    alter table(:provisioning_environments) do
      add :first_deployed_at, :utc_datetime_usec
    end
  end
end
