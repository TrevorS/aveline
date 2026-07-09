defmodule Aveline.Runtime.Evaluator do
  @moduledoc """
  Evaluates one code cell's source against a CONTEXT — the accumulated
  `binding` plus `Macro.Env` of the parent cell, so `import` / `alias`
  / `require` carry between cells exactly like variables do
  (Livebook's context chain). The mechanics are borrowed from
  Livebook: stdout is captured by swapping the evaluating process's
  group leader for a `StringIO` device, `frame/1` is injected as an
  import (see `Aveline.Runtime.CellHelpers`), every raise / throw /
  exit is caught as a value, and a hard per-eval ceiling is enforced by
  running the eval in an unlinked supervised task that gets brutally
  killed on overrun. The StringIO device belongs to the caller, not the
  task, so stdout captured before a kill survives it.

  The result is rendered to its `inspect` string INSIDE the task, on
  the node the value lives on — a peer node's dataframe holds a NIF
  resource that is only printable there, and a pathological `inspect`
  stays under the same ceiling as the eval itself.

  Never raises toward the caller: the outcome is
  `{:ok, %{value, result, context, stdout, stdout_truncated}}` or
  `{:error, %{message, stdout, stdout_truncated}}`.
  """

  alias Aveline.Runtime.CellHelpers

  @default_timeout_ms 10_000
  @stdout_cap_chars 65_536

  def default_timeout_ms, do: @default_timeout_ms

  @doc "The context a cell with no evaluated parent starts from."
  def initial_context, do: %{binding: [], env: eval_env()}

  @doc """
  The context donated by the nearest earlier cell that has evaluated —
  Livebook's linear context chain, without copies for cells that never
  ran. `contexts` maps cell refs to stored contexts; `parents` are the
  earlier code cell ids in doc order.
  """
  def parent_context(contexts, parents) when is_map(contexts) and is_list(parents) do
    parents
    |> Enum.reverse()
    |> Enum.find_value(initial_context(), &contexts[&1])
  end

  @doc """
  Evaluate `source` against `context` (see `initial_context/0`). `opts`:

    * `:timeout_ms` — per-eval ceiling (default #{@default_timeout_ms})
    * `:frame_resolver` — 1-arity fun behind `frame("name")`, closing
      over the notebook's captured frame runs
    * `:task_supervisor` — the `Task.Supervisor` evals run under
      (default `Aveline.TaskSupervisor`; the peer node names its own)
  """
  def eval(source, context, opts \\ []) when is_binary(source) and is_map(context) do
    timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
    resolver = Keyword.get(opts, :frame_resolver)
    task_supervisor = Keyword.get(opts, :task_supervisor, Aveline.TaskSupervisor)

    {:ok, capture} = StringIO.open("")

    task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        Process.group_leader(self(), capture)
        if resolver, do: CellHelpers.put_frame_resolver(resolver)

        # with_diagnostics: a CompileError's banner is just "cannot
        # compile file" — the actual "undefined variable" lives in the
        # collected diagnostics.
        {outcome, diagnostics} =
          Code.with_diagnostics(fn ->
            try do
              quoted = Code.string_to_quoted!(source, file: "cell")

              {value, binding, env} =
                Code.eval_quoted_with_env(quoted, context.binding, context.env)

              {:ok, value, render_result(value), %{binding: binding, env: env}}
            catch
              kind, error ->
                {:error, Exception.format_banner(kind, error, __STACKTRACE__)}
            end
          end)

        with {:error, message} <- outcome do
          {:error, append_diagnostics(message, diagnostics)}
        end
      end)

    outcome =
      case Task.yield(task, timeout_ms) do
        {:ok, result} ->
          Process.demonitor(task.ref, [:flush])
          result

        {:exit, reason} ->
          {:error, "evaluation crashed: " <> exit_message(reason)}

        nil ->
          case Task.shutdown(task, :brutal_kill) do
            {:ok, result} -> result
            _ -> {:error, "evaluation timed out after #{timeout_ms}ms and was killed"}
          end
      end

    {stdout, truncated?} = drain(capture)

    case outcome do
      {:ok, value, result, new_context} ->
        {:ok,
         %{
           value: value,
           result: result,
           context: new_context,
           stdout: stdout,
           stdout_truncated: truncated?
         }}

      {:error, message} ->
        {:error, %{message: message, stdout: stdout, stdout_truncated: truncated?}}
    end
  end

  # inspect is the result surface: always a string, always JSON-safe,
  # and Explorer dataframes print their own table preview.
  defp render_result(value),
    do: inspect(value, pretty: true, limit: 100, printable_limit: 4_096, width: 98)

  defp append_diagnostics(message, diagnostics) do
    case for %{severity: :error, message: detail} <- diagnostics, do: detail do
      [] -> message
      details -> Enum.join([message | details], "\n")
    end
  end

  # `frame/1` is importable in every cell; everything else is the stock
  # eval environment (Kernel and friends).
  defp eval_env do
    env = :elixir.env_for_eval(file: "cell")
    %{env | functions: [{CellHelpers, [frame: 1]} | env.functions]}
  end

  defp exit_message(%{__exception__: true} = e), do: Exception.message(e)
  defp exit_message({%{__exception__: true} = e, _stacktrace}), do: Exception.message(e)
  defp exit_message(other), do: inspect(other) |> String.slice(0, 200)

  defp drain(capture) do
    {:ok, {_input, output}} = StringIO.close(capture)

    if String.length(output) > @stdout_cap_chars,
      do: {String.slice(output, 0, @stdout_cap_chars) <> "\n… (stdout truncated)", true},
      else: {output, false}
  end
end
