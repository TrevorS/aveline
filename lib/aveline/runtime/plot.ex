defmodule Aveline.Runtime.Plot do
  @moduledoc """
  A plot a code cell asks for, built by `Aveline.Runtime.Bridge.plot/2`.

  It is a marker the runtime recognizes on a cell's return value: `data`
  (an `Explorer.DataFrame`, a `%{"columns" => …, "rows" => …}` map, or a
  list of maps — coerced to columns/rows by the runtime) plus `viz` (the
  same chart grammar frame cells use: `%{"type" => "bar"|"line"|"combo"|
  "table", "x" => …, "y" => …}`). The renderer runs it through the same
  `AvelineWeb.ChartRenderer` + ECharts hook a chart block uses, so a code
  cell plots with zero new rendering machinery.
  """
  @enforce_keys [:data, :viz]
  defstruct [:data, :viz]
end
