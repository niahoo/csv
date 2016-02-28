defmodule CSV.Decoder do

  @moduledoc ~S"""
  The Decoder CSV module sends lines of delimited values from a stream to the parser and converts
  rows coming from the CSV parser module to a consumable stream.
  In setup, it parallelises lexing and parsing, as well as different lexer/parser pairs as pipes.
  The number of pipes can be controlled via options.
  """
  alias CSV.LineAggregator
  alias CSV.Parser
  alias CSV.Lexer
  alias CSV.Defaults

  @doc """
  Decode a stream of comma-separated lines into a table.
  You can control the number of parallel operations via the option `:num_pipes` - 
  default is the number of erlang schedulers times 3.

  ## Options

  These are the options:

    * `:separator`   – The separator token to use, defaults to `?,`. Must be a codepoint (syntax: ? + (your separator)).
    * `:delimiter`   – The delimiter token to use, defaults to `\r\n`. Must be a string.
    * `:strip_cells` – When set to true, will strip whitespace from cells. Defaults to false.
    * `:num_pipes`   – Will be deprecated in 2.0 - see num_workers
    * `:num_workers` – The number of parallel operations to run when producing the stream.
    * `:worker_work_ratio` – The available work per worker, defaults to 5. Higher rates will mean more work sharing, but might also lead to work fragmentation slowing down the queues.
    * `:multiline_escape` – Whether escape sequences can span linebreaks.
    * `:headers`     – When set to `true`, will take the first row of the csv and use it as
      header values.
      When set to a list, will use the given list as header values.
      When set to `false` (default), will use no header values.
      When set to anything but `false`, the resulting rows in the matrix will
      be maps instead of lists.

  ## Examples

  Convert a filestream into a stream of rows:

      iex> File.stream!(\"data.csv\") |>
      iex> CSV.Decoder.decode |>
      iex> Enum.take(2)
      [[\"a\",\"b\",\"c\"], [\"d\",\"e\",\"f\"]]

  Map an existing stream of lines separated by a token to a stream of rows with a header row:

      iex> [\"a;b\",\"c;d\", \"e;f\"] |>
      iex> Stream.map(&(&1)) |>
      iex> CSV.Decoder.decode(separator: ?;, headers: true) |>
      iex> Enum.take(2)
      [%{\"a\" => \"c\", \"b\" => \"d\"}, %{\"a\" => \"e\", \"b\" => \"f\"}]

  Map an existing stream of lines separated by a token to a stream of rows with a given header row:

      iex> [\"a;b\",\"c;d\", \"e;f\"] |>
      iex> Stream.map(&(&1)) |>
      iex> CSV.Decoder.decode(separator: ?;, headers: [:x, :y]) |>
      iex> Enum.take(2)
      [%{:x => \"a\", :y => \"b\"}, %{:x => \"c\", :y => \"d\"}]
  """

  def decode(stream, options \\ []) do
    { headers, stream } = options
                          |> Keyword.get(:headers, false)
                          |> get_headers!(stream, options)

    num_workers = options
                  |> Keyword.get(:num_workers, options
                  |> Keyword.get(:num_pipes, Defaults.num_workers))

    multiline_escape = options
                        |> Keyword.get(:multiline_escape, true)


    stream
    |> aggregate(multiline_escape)
    |> Stream.with_index
    |> ParallelStream.map(fn { line, index } ->
      { line, index }
      |> Lexer.lex(options)
      |> lex_to_parse
      |> Parser.parse(options)
      |> build_row(headers)
    end, options |> Keyword.merge(num_workers: num_workers))
    |> handle_errors
  end
  defp aggregate(stream, true) do
    stream |> LineAggregator.aggregate
  end
  defp aggregate(stream, false) do
    stream
  end

  defp lex_to_parse({ :ok, tokens, index }) do
    { tokens, index }
  end
  defp lex_to_parse(result) do
    result
  end

  defp build_row({ :ok, data, _ }, headers) when is_list(headers) do
    headers |> Enum.zip(data) |> Enum.into(%{})
  end
  defp build_row({ :ok, data, _ }, _) do
    data
  end
  defp build_row(error, _) do
    error
  end

  defp get_headers!(headers, stream, _) when is_list(headers) do
    { headers, stream }
  end
  defp get_headers!(headers, stream, options) when headers do
    headers_line = stream
      |> Enum.take(1)
      |> List.first

    headers = { headers_line, 0 }
      |> Lexer.lex(options)
      |> lex_to_parse
      |> Parser.parse(options)
      |> build_row(nil)

    { headers, stream |> Stream.drop(1) }
  end
  defp get_headers!(_, stream, _) do
    { false, stream }
  end

  defp handle_errors(stream) do
    stream |> Stream.map(&handle_error_for_result!/1)
  end
  defp handle_error_for_result!({ :error, mod, message, index }) do
    raise mod, message: message, line: index + 1
  end
  defp handle_error_for_result!(result) do
    result
  end

end
