defmodule Aveline.LocalSeed do
  @moduledoc """
  First-boot seed for single-user local deploys (DEPLOY_MODE=local).

  When the database has no users, creates one user + workspace + API token
  through the normal signup flow and logs the plaintext token once; it is
  never reconstructible afterwards. Any boot that finds an existing user
  seeds nothing, so re-running is safe.

  `Aveline.Application` runs `boot/0` as a one-shot task after the
  supervision tree is up — signup broadcasts over `Aveline.PubSub`, so the
  seed cannot run from the migrate-on-boot eval, where only the Repo is
  started.
  """

  require Logger

  alias Aveline.Accounts
  alias Aveline.Repo

  @username "local"
  @workspace_name "Local"

  @doc """
  One-shot boot task: run the seed and log the outcome. Every failure —
  including an unexpected raise — becomes a log line, never a crash, so
  the app always finishes booting.
  """
  def boot do
    report(run())
  rescue
    e -> report({:error, Exception.message(e)})
  end

  @doc """
  Seed the single local user if the database has none. Returns
  `{:ok, %{user, workspace, token}}` (token is plaintext, shown once),
  `:already_seeded`, or `{:error, reason}`.
  """
  def run do
    if Repo.exists?(Accounts.base_query()) do
      :already_seeded
    else
      Accounts.signup(%{"username" => @username, "workspace_name" => @workspace_name})
    end
  end

  defp report({:ok, %{user: user, token: token}}) do
    Logger.info("""

    == Aveline local mode: first-boot seed ==
    Created user #{user.username} with an API token. This token is shown
    ONCE and cannot be recovered — to use the CLI, run:

      aveline login --api-url <this host>

    and paste the token when prompted:

      #{token}
    """)
  end

  defp report(:already_seeded), do: :ok

  defp report({:error, reason}) do
    Logger.error("Aveline local mode: first-boot seed failed: #{inspect(reason)}")
  end
end
