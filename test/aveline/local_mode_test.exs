defmodule Aveline.LocalModeTest do
  # async: false — these mutate the global :deploy_mode application env.
  use Aveline.DataCase, async: false

  import ExUnit.CaptureLog

  alias Aveline.Accounts
  alias Aveline.Config
  alias Aveline.Release
  alias Aveline.Tokens

  setup do
    original = Application.get_env(:aveline, :deploy_mode)
    # The seed logs the token at :info; the suite runs at :warning by default.
    log_level = Logger.level()
    Logger.configure(level: :info)

    on_exit(fn ->
      restore(:deploy_mode, original)
      Logger.configure(level: log_level)
    end)

    :ok
  end

  describe "Config.local_mode?/0" do
    test "defaults to cloud" do
      Application.delete_env(:aveline, :deploy_mode)
      assert Config.deploy_mode() == "cloud"
      refute Config.local_mode?()
    end

    test "is true only for DEPLOY_MODE=local" do
      Application.put_env(:aveline, :deploy_mode, "local")
      assert Config.local_mode?()

      Application.put_env(:aveline, :deploy_mode, "cloud")
      refute Config.local_mode?()
    end
  end

  describe "seeding" do
    test "maybe_seed_local/0 is a no-op in cloud mode" do
      Application.put_env(:aveline, :deploy_mode, "cloud")
      assert Release.maybe_seed_local() == :noop
      refute Repo.exists?(Accounts.base_query())
    end

    test "seed_local/0 creates one user + workspace + token, logged once" do
      Application.put_env(:aveline, :deploy_mode, "local")

      log = capture_log([level: :info], fn -> assert Release.seed_local() == :seeded end)

      user = Repo.one!(Accounts.base_query())
      assert user.username == "local"

      # the logged token is real and belongs to the seeded user
      [_, plaintext] = Regex.run(~r/(avl_[A-Za-z0-9_-]{32})/, log)
      assert %{user_id: uid} = Tokens.verify(plaintext)
      assert uid == user.id
    end

    test "seed_local/0 is idempotent — a second call is a no-op" do
      Application.put_env(:aveline, :deploy_mode, "local")

      assert capture_log([level: :info], fn -> assert Release.seed_local() == :seeded end) =~
               "avl_"

      second = capture_log([level: :info], fn -> assert Release.seed_local() == :exists end)
      refute second =~ "avl_"

      assert Repo.aggregate(Accounts.base_query(), :count) == 1
    end
  end

  defp restore(key, nil), do: Application.delete_env(:aveline, key)
  defp restore(key, value), do: Application.put_env(:aveline, key, value)
end
