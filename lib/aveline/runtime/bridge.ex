defmodule Aveline.Runtime.Bridge do
  @moduledoc """
  The functions a code cell may call into Aveline. Imported into the
  evaluation scope (via a `Macro.Env` the backend hands to
  `Code.eval_string`), so a cell writes `query("orders")` — no dot, no
  alias — and gets a plain result map back.

  Ways in — every reader returns `%{"columns" => …, "rows" => …}` (the shape
  a chart run produces), with a `_df` twin that returns an
  `Explorer.DataFrame`:

    * `query/1` / `query_df/1` — read a named catalog query's latest result.
    * `sql/1` / `sql_df/1` — run ad-hoc DuckDB SQL over the catalog (name
      catalog queries as tables, or use DuckDB's own functions).
    * `from_source/2` / `from_source_df/2` — run raw SQL against a named
      external data source (Postgres/MySQL/Redshift), through the chart cache.

  `to_df/1` converts any columns/rows map to a dataframe; `to_tensor/1`
  bridges Explorer data into an `Nx` tensor for `Scholar`; `plot/2` turns
  data into a chart; `materialize/2` saves a computed result back to the
  catalog as a named query, closing the loop from a code cell to a frame. `Explorer.DataFrame` (aliased `DF`) and
  `Explorer.Series` are in scope in every cell, and the ML/stats stack
  (`Nx`, `Scholar`, `Statistics`) is available — so the engines and the
  libraries compose: DuckDB (or an external source) does the SQL, Explorer
  does the in-cell dataframe work, Scholar/Nx do the modelling, `plot/2`
  renders it.

  The evaluating process carries its workspace in the process dictionary
  (`:aveline_runtime_ws_id`, set by the backend per eval), so the bridge
  needs no explicit context argument. A failed lookup raises inside the
  cell — which the backend catches and records as an error run — rather
  than returning a silent empty table.
  """

  @ws_key :aveline_runtime_ws_id
  @user_key :aveline_runtime_user_id
  @sql_cap 10_000

  @doc """
  Read the latest result of catalog query `name`, as
  `%{"columns" => [...], "rows" => [[...]]}`. Runs the query through the
  same async chart engine a frame cell / chart uses (`Docs.run_chart` →
  `Catalog` → sandboxed DuckDB), so a code cell composes over live catalog
  data. Raises if the query is missing or its run errors — the backend
  turns that into a captured error run.

  Tests may stub the resolver with the `:runtime_query_fun` app env
  (`fn ws_id, name -> result_map end`) to avoid standing up a data source.
  """
  def query(name) when is_binary(name) do
    ws_id =
      Process.get(@ws_key) ||
        raise "query/1 is only available inside a running code cell"

    case resolve(ws_id, name) do
      %{"error" => msg} -> raise "query(#{inspect(name)}) failed: #{msg}"
      %{"columns" => _, "rows" => _} = ok -> ok
      other -> other
    end
  end

  def query(other),
    do: raise(ArgumentError, "query/1 takes a catalog query name (string), got: #{inspect(other)}")

  @doc """
  Like `query/1`, but returns an `Explorer.DataFrame` instead of a raw
  columns/rows map — the bridge from the DuckDB catalog into Explorer.
  Column dtypes are inferred by Explorer.

      df = query_df("world_cities")
      DF.filter(df, population_m > 20) |> DF.arrange(desc: population_m)
  """
  def query_df(name) when is_binary(name), do: name |> query() |> to_df()

  @doc """
  Convert a `%{"columns" => [...], "rows" => [[...]]}` map (a `query/1`
  result, or one you built) into an `Explorer.DataFrame`. Rows are lists in
  column order.
  """
  def to_df(%{"columns" => cols, "rows" => rows}) when is_list(cols) and is_list(rows) do
    series =
      cols
      |> Enum.with_index()
      |> Map.new(fn {col, i} -> {col, Enum.map(rows, &Enum.at(&1, i))} end)

    Explorer.DataFrame.new(series)
  end

  def to_df(other),
    do: raise(ArgumentError, ~s|to_df/1 takes a %{"columns" => _, "rows" => _} map, got: #{inspect(other)}|)

  @doc """
  Convert data into an `Nx.tensor` for `Scholar` / `Nx`. A `Series` or list
  becomes a 1-D tensor (a target `y`); a `DataFrame` becomes a 2-D
  `{n_rows, n_cols}` tensor (a feature matrix `X`).

      x = query_df("world_cities") |> DF.select(["area_km2"]) |> to_tensor()
      y = query_df("world_cities")["population_m"] |> to_tensor()
      Scholar.Linear.LinearRegression.fit(x, y)
  """
  def to_tensor(%Explorer.Series{} = series),
    do: series |> Explorer.Series.to_list() |> Nx.tensor()

  def to_tensor(%Explorer.DataFrame{} = df) do
    df
    |> Explorer.DataFrame.names()
    |> Enum.map(fn col -> Explorer.Series.to_list(df[col]) end)
    |> Nx.tensor()
    |> Nx.transpose()
  end

  def to_tensor(list) when is_list(list), do: Nx.tensor(list)

  @doc """
  Ask for a plot of `data` (an `Explorer.DataFrame`, a `%{"columns", "rows"}`
  map, or a list of maps). Returns an `Aveline.Runtime.Plot` — return it from
  a cell and it renders as a chart through the same ECharts path a frame cell
  uses.

  Options mirror the chart viz grammar: `type:` (`:bar` | `:line` | `:combo`
  | `:scatter` | `:table`, default `:bar`), `x:` and `y:` (column names), and
  for `:scatter` an optional `color:` (a categorical column — points are
  colored and split into one series per value).

      query_df("world_cities")
      |> DF.mutate(density: population_m * 1_000_000 / area_km2)
      |> plot(type: :bar, x: "city", y: "density")

      # a PCA / cluster scatter colored by category
      plot(projected, type: :scatter, x: "pc1", y: "pc2", color: "species")
  """
  def plot(data, opts \\ []) when is_list(opts) do
    %Aveline.Runtime.Plot{data: data, viz: build_viz(opts)}
  end

  defp build_viz(opts) do
    %{"type" => to_string(Keyword.get(opts, :type, :bar))}
    |> put_opt("x", opts[:x])
    |> put_opt("y", opts[:y])
    |> put_opt("color", opts[:color])
  end

  defp put_opt(map, _key, nil), do: map
  defp put_opt(map, key, value), do: Map.put(map, key, to_string(value))

  @doc """
  Run SQL over the workspace catalog — the same sandboxed DuckDB engine a
  DERIVED query uses. Reference existing catalog queries by name as tables,
  or use DuckDB's own functions (`generate_series`, `VALUES`, …). Accepts a
  raw SQL string OR an Ecto query (a schemaless `from c in "catalog_query"`,
  since a catalog-query name is a table name) — the query is rendered to SQL
  with its params inlined. Returns `%{"columns" => …, "rows" => …}`; raises
  on error.

      sql("SELECT continent, count(*) AS n FROM world_cities GROUP BY 1")

      sql(from c in "world_cities",
        where: c.population_m > 20, group_by: c.continent,
        select: %{continent: c.continent, n: count()})

  `sql_df/1` returns the same as an `Explorer.DataFrame`.
  """
  def sql(queryable), do: unwrap(run_catalog(ws!(), to_sql_string(queryable)))

  def sql_df(queryable), do: queryable |> sql() |> to_df()

  @doc """
  Run raw SQL against a named external data source (its own dialect —
  Postgres, MySQL, Redshift), through the same 60s cache charts use.
  Returns `%{"columns" => …, "rows" => …}`; raises if the source is missing
  or the query errors.

      from_source("prod", "SELECT count(*) FROM users")

  `from_source_df/2` returns an `Explorer.DataFrame`.
  """
  def from_source(source, queryable) when is_binary(source),
    do: unwrap(run_source(ws!(), source, to_sql_string(queryable)))

  def from_source_df(source, queryable) when is_binary(source),
    do: source |> from_source(queryable) |> to_df()

  # sql/1 and from_source/2 accept either a raw SQL string or an Ecto query.
  # An Ecto query (typically a schemaless `from m in "some_catalog_query"`,
  # since a catalog-query name IS a table name to DuckDB) is rendered to SQL
  # via the Repo's adapter; its bind params are inlined as literals because
  # the engine/runner take a complete string, not a parameterized statement.
  # The rendered dialect is Postgres — a fine match for DuckDB and Postgres
  # sources; other source dialects may need a raw string.
  defp to_sql_string(sql) when is_binary(sql), do: sql

  defp to_sql_string(%Ecto.Query{} = query) do
    {sql, params} = Ecto.Adapters.SQL.to_sql(:all, Aveline.Repo, query)
    inline_params(sql, params)
  end

  defp to_sql_string(other),
    do: raise(ArgumentError, "expected a SQL string or an Ecto query, got: #{inspect(other)}")

  defp inline_params(sql, params) do
    Regex.replace(~r/\$(\d+)/, sql, fn _, n ->
      params |> Enum.at(String.to_integer(n) - 1) |> sql_literal()
    end)
  end

  defp sql_literal(nil), do: "NULL"
  defp sql_literal(true), do: "TRUE"
  defp sql_literal(false), do: "FALSE"
  defp sql_literal(v) when is_integer(v) or is_float(v), do: to_string(v)
  defp sql_literal(%Date{} = v), do: "'#{Date.to_iso8601(v)}'"
  defp sql_literal(%DateTime{} = v), do: "'#{DateTime.to_iso8601(v)}'"
  defp sql_literal(%NaiveDateTime{} = v), do: "'#{NaiveDateTime.to_iso8601(v)}'"
  defp sql_literal(%Decimal{} = v), do: Decimal.to_string(v)
  defp sql_literal(v) when is_binary(v), do: quote_str(v)
  defp sql_literal(v), do: v |> to_string() |> quote_str()

  defp quote_str(s), do: "'" <> String.replace(s, "'", "''") <> "'"

  @doc """
  Run an Ecto query against the app's own database and return the rows —
  Ecto instead of a SQL string. `Ecto.Query` is imported in every cell, so
  `from`/`where`/`select` need no qualification; use a schemaless string
  source or your schemas. `db_df/1` returns an `Explorer.DataFrame`.

      db(from d in "docs",
        where: d.kind == "notebook" and is_nil(d.deleted_at),
        select: %{slug: d.slug, title: d.title})
  """
  def db(queryable), do: Aveline.Repo.all(queryable)

  def db_df(queryable), do: queryable |> db() |> Explorer.DataFrame.new()

  defp ws!, do: Process.get(@ws_key) || raise("this bridge is only available inside a running code cell")

  # The catalog engine and source runner answer with {:ok, result} /
  # {:error, msg}; the chart path answers with a bare map or %{"error"}.
  # Normalize all of them to a bare columns/rows map, raising on failure.
  defp unwrap({:ok, result}), do: unwrap(result)
  defp unwrap({:error, msg}), do: raise("query failed: #{msg}")
  defp unwrap(%{"error" => msg}), do: raise("query failed: #{msg}")
  defp unwrap(%{"columns" => _, "rows" => _} = ok), do: ok
  defp unwrap(other), do: other

  defp run_catalog(ws_id, sql) do
    case Application.get_env(:aveline, :runtime_sql_fun) do
      fun when is_function(fun, 2) -> fun.(ws_id, sql)
      _ -> Aveline.DataSources.Catalog.run(ws_id, sql)
    end
  end

  defp run_source(ws_id, name, sql) do
    case Application.get_env(:aveline, :runtime_source_fun) do
      fun when is_function(fun, 3) ->
        fun.(ws_id, name, sql)

      _ ->
        case Aveline.DataSources.get_current_by_name(ws_id, name) do
          nil -> %{"error" => "data source #{inspect(name)} not found in this workspace"}
          ds -> Aveline.DataSources.Cache.run(ds, sql)
        end
    end
  end

  @doc """
  Save `data` (a `DataFrame`, a `%{"columns", "rows"}` map, or a list of
  maps) as a catalog query named `name`, so frame cells and other cells can
  reference it by name — the loop from a computed result back into the
  catalog. The data is encoded as a `VALUES` table; re-running upserts a new
  version. Bounded by the catalog's #{@sql_cap}-char SQL limit, so aggregate
  or sample large results first.

      cleaned = query_df("penguins") |> DF.filter(not is_nil(sex))
      materialize("penguins_clean", cleaned)
      # now: a frame cell with query_ref "penguins_clean", or sql("… FROM penguins_clean")
  """
  def materialize(name, data) when is_binary(name) do
    ws_id = ws!()
    user_id = user!()
    {cols, rows} = columns_rows(data)
    sql = values_sql(cols, rows)

    if String.length(sql) > @sql_cap do
      raise "materialize(#{inspect(name)}): #{length(rows)} rows render to #{String.length(sql)} chars, over the #{@sql_cap} catalog limit — aggregate or sample first"
    end

    case upsert_query(ws_id, name, sql, user_id) do
      {:ok, _query} -> %{materialized: name, rows: length(rows), columns: cols}
      {:error, reason} -> raise "materialize(#{inspect(name)}) failed: #{inspect(reason)}"
    end
  end

  defp upsert_query(ws_id, name, sql, user_id) do
    case Aveline.DataSources.Queries.get_current_by_name(ws_id, name) do
      nil -> Aveline.DataSources.Queries.create(ws_id, %{name: name, sql: sql}, user_id)
      current -> Aveline.DataSources.Queries.edit(current, %{sql: sql}, user_id)
    end
  end

  defp columns_rows(%Explorer.DataFrame{} = df) do
    cols = Explorer.DataFrame.names(df)
    columns = Enum.map(cols, fn c -> Explorer.Series.to_list(df[c]) end)
    {cols, Enum.zip_with(columns, & &1)}
  end

  defp columns_rows(%{"columns" => cols, "rows" => rows}), do: {cols, rows}

  defp columns_rows([first | _] = maps) when is_map(first) do
    keys = Map.keys(first)
    {Enum.map(keys, &to_string/1), Enum.map(maps, fn m -> Enum.map(keys, &m[&1]) end)}
  end

  defp columns_rows(other),
    do:
      raise(
        ArgumentError,
        "materialize/2 takes a DataFrame, a columns/rows map, or a list of maps, got: #{inspect(other)}"
      )

  defp values_sql(cols, rows) do
    idents = Enum.map_join(cols, ", ", &quote_ident/1)

    values =
      Enum.map_join(rows, ", ", fn row ->
        "(" <> Enum.map_join(row, ", ", &sql_literal/1) <> ")"
      end)

    "SELECT * FROM (VALUES " <> values <> ") AS t(" <> idents <> ")"
  end

  defp quote_ident(name), do: ~s(") <> String.replace(to_string(name), ~s("), ~s("")) <> ~s(")

  @doc false
  # Set/clear the workspace + acting-user binding around an eval. The backend
  # calls these on the evaluating process so `query/1` knows which workspace
  # it reads and `materialize/2` knows who is writing.
  def put_workspace(ws_id), do: Process.put(@ws_key, ws_id)
  def put_user(user_id), do: Process.put(@user_key, user_id)

  defp user!,
    do:
      Process.get(@user_key) || raise("materialize/2 needs an acting user — only available inside a running code cell")

  defp resolve(ws_id, name) do
    case Application.get_env(:aveline, :runtime_query_fun) do
      fun when is_function(fun, 2) -> fun.(ws_id, name)
      _ -> Aveline.Docs.run_chart(ws_id, %{"query_ref" => name})
    end
  end
end
