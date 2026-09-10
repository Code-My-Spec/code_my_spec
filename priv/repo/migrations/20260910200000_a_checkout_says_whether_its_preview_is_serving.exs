defmodule CodeMySpec.Repo.Migrations.ACheckoutSaysWhetherItsPreviewIsServing do
  @moduledoc """
  Whether the application this checkout runs is actually answering.

  `code_on_running_copy` proves the *code* is on the running copy. It says
  nothing about whether anything is serving it, and the two came apart within a
  day of shipping: Broken Oaths' preview was down, the gate was satisfied, and
  a QA agent stood in front of a connection refused with the graph reporting
  the story ready to test. It then asked to restart the app itself — which
  would have started it on code that did not contain the work it was there to
  verify.

  So the rule QA depends on is both halves: the code is here *and* the thing
  QA browses is up. This is the second half.

  ## Measured against the address QA uses

  `preview_url`, not a local port. A checkout's app answers on a port only its
  own machine knows, and QA browses the preview — so a check against localhost
  can pass while the address anyone actually opens is dead. The harness holds
  the URL in its `.cms_harness.json` already.

  ## Three states, not two

  `serving`, `erroring` and `down` are different things to be told. A 500 is an
  application that came up and is failing, which is a QA finding; a refused
  connection is an application that is not there, which is not. Collapsing them
  into a boolean would make the second look like the first and send QA to file
  defects against a story whose app never started.

  Nullable, and deliberately: never checked is not the same as down, and only
  the second is something to act on.
  """
  use Ecto.Migration

  def change do
    alter table(:working_copies) do
      add :preview_status, :string
      add :preview_checked_at, :utc_datetime_usec
    end
  end
end
