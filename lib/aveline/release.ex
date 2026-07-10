defmodule Aveline.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  require Logger

  alias Aveline.Accounts
  alias Aveline.Repo

  @app :aveline

  # Identity of the auto-seeded owner in a single-user local deployment.
  @local_username "local"
  @local_workspace_name "Local"

  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end

    maybe_seed_local()
  end

  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  On a single-user local deployment (`DEPLOY_MODE=local`), ensure a first
  user + personal workspace + API token exist so `aveline login` works with
  no signup. A no-op in cloud mode. Runs from `migrate/0` on every boot
  (starting the repo itself); the token is logged only on the boot that
  creates it.
  """
  def maybe_seed_local do
    if Aveline.Config.local_mode?() do
      {:ok, result, _} = Ecto.Migrator.with_repo(hd(repos()), fn _repo -> seed_local() end)
      result
    else
      :noop
    end
  end

  @doc """
  The seed body, split from `maybe_seed_local/0` so it can run against an
  already-started repo. Idempotent: once any user exists it does nothing.
  Returns `:seeded`, `:exists`, or `:error`.
  """
  def seed_local do
    if Repo.exists?(Accounts.base_query()) do
      :exists
    else
      case Accounts.signup(%{
             "username" => @local_username,
             "workspace_name" => @local_workspace_name
           }) do
        {:ok, %{token: plaintext}} ->
          Logger.info(local_seed_message(plaintext))
          :seeded

        {:error, reason} ->
          Logger.error("[local seed] failed to create the first user: #{inspect(reason)}")
          :error
      end
    end
  end

  defp local_seed_message(plaintext) do
    """
    [local seed] DEPLOY_MODE=local — created the first user "#{@local_username}" \
    and workspace "#{@local_workspace_name}". Point the CLI at this deployment \
    with the token below (shown only once):

        aveline login --api-url http://localhost:7151

        API token: #{plaintext}
    """
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
