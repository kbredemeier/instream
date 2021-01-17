defmodule Instream.Connection.QueryRunner do
  @moduledoc false

  alias Instream.Connection.JSON
  alias Instream.Log.Metadata
  alias Instream.Log.PingEntry
  alias Instream.Log.QueryEntry
  alias Instream.Log.StatusEntry
  alias Instream.Log.WriteEntry
  alias Instream.Query
  alias Instream.Query.Headers
  alias Instream.Query.URL
  alias Instream.Response

  @doc """
  Executes `:ping` queries.
  """
  @spec ping(Keyword.t(), module) :: :pong | :error
  def ping(opts, conn) do
    config = conn.config()
    headers = Headers.assemble(config, opts)
    url = URL.ping(config)

    {query_time, response} =
      :timer.tc(fn ->
        config[:http_client].request(:head, url, headers, "", http_opts(config, opts))
      end)

    result =
      case response do
        {:ok, 204, _} -> :pong
        _ -> :error
      end

    if false != opts[:log] do
      status =
        case response do
          {:ok, status, _} -> status
          _ -> 0
        end

      log(config[:loggers], %PingEntry{
        host: config[:host],
        result: result,
        metadata: %Metadata{
          query_time: query_time,
          response_status: status
        }
      })
    end

    result
  end

  @doc """
  Executes `:read` queries.
  """
  @spec read(Query.t(), Keyword.t(), module) :: any
  def read(%Query{payload: query_payload} = query, opts, conn) do
    config = conn.config()
    headers = Headers.assemble(config, opts)

    body = read_body(conn, query, opts)
    method = read_method(config, opts)
    url = read_url(conn, query, opts)

    {query_time, response} =
      :timer.tc(fn ->
        config[:http_client].request(method, url, headers, body, http_opts(config, opts))
      end)

    case response do
      {:ok, status, _, _} ->
        result = Response.maybe_parse(response, conn, opts)

        if false != opts[:log] do
          log(config[:loggers], %QueryEntry{
            query: query_payload,
            result: result,
            metadata: %Metadata{
              query_time: query_time,
              response_status: status
            }
          })
        end

        result

      {:error, _} ->
        response
    end
  end

  @doc """
  Execute `:status` queries.
  """
  @spec status(Keyword.t(), module) :: :ok | :error
  def status(opts, conn) do
    config = conn.config()
    headers = Headers.assemble(config, opts)
    url = URL.status(config)

    {query_time, response} =
      :timer.tc(fn ->
        config[:http_client].request(:head, url, headers, "", http_opts(config, opts))
      end)

    result =
      case response do
        {:ok, 204, _} -> :ok
        _ -> :error
      end

    if false != opts[:log] do
      status =
        case response do
          {:ok, status, _} -> status
          _ -> 0
        end

      log(config[:loggers], %StatusEntry{
        host: config[:host],
        result: result,
        metadata: %Metadata{
          query_time: query_time,
          response_status: status
        }
      })
    end

    result
  end

  @doc """
  Executes `:version` queries.
  """
  @spec version(Keyword.t(), module) :: any
  def version(opts, conn) do
    config = conn.config()
    headers = Headers.assemble(config, opts)
    url = URL.ping(config)
    response = config[:http_client].request(:head, url, headers, "", http_opts(config, opts))

    case response do
      {:ok, 204, headers} ->
        case List.keyfind(headers, "X-Influxdb-Version", 0) do
          {"X-Influxdb-Version", version} -> version
          _ -> "unknown"
        end

      _ ->
        :error
    end
  end

  @doc """
  Executes `:write` queries.
  """
  @spec write(Query.t(), Keyword.t(), map) :: any
  def write(%Query{payload: points} = query, opts, conn) do
    config = conn.config()

    {query_time, result} =
      :timer.tc(fn ->
        query
        |> config[:writer].write(opts, conn)
        |> Response.maybe_parse(conn, opts)
      end)

    if false != opts[:log] do
      log(config[:loggers], %WriteEntry{
        points: length(points),
        result: result,
        metadata: %Metadata{
          query_time: query_time,
          response_status: 0
        }
      })
    end

    result
  end

  defp http_opts(config, opts) do
    call_opts = Keyword.get(opts, :http_opts, [])
    config_opts = Keyword.get(config, :http_opts, [])

    special_opts =
      case opts[:timeout] do
        nil -> []
        timeout -> [recv_timeout: timeout]
      end

    special_opts
    |> Keyword.merge(config_opts)
    |> Keyword.merge(call_opts)
  end

  defp log([_ | _] = loggers, entry) do
    Enum.each(loggers, fn {mod, fun, extra_args} ->
      apply(mod, fun, [entry | extra_args])
    end)
  end

  defp log(_, _), do: :ok

  defp read_body(conn, %{payload: query_payload}, opts) do
    config = conn.config()

    case {config[:version], opts[:query_language]} do
      {:v2, :flux} ->
        JSON.encode(
          %{
            type: "flux",
            query: query_payload
          },
          conn
        )

      {:v2, _} ->
        JSON.encode(
          %{
            type: "influxql",
            bucket: opts[:bucket] || config[:bucket],
            query: query_payload
          },
          conn
        )

      {:v1, :flux} ->
        query_payload

      {:v1, _} ->
        ""
    end
  end

  defp read_method(config, opts) do
    case {config[:version], opts[:query_language]} do
      {:v2, _} -> :post
      {:v1, :flux} -> :post
      {:v1, _} -> opts[:method] || :get
    end
  end

  defp read_url(conn, %{opts: query_opts, payload: query_payload}, opts) do
    config = conn.config()
    url = URL.query(config, opts, query_opts)

    url =
      case opts[:params] do
        params when is_map(params) ->
          params
          |> JSON.encode(conn)
          |> URL.append_json_params(url)

        _ ->
          url
      end

    case {config[:version], opts[:query_language]} do
      {:v2, _} -> url
      {:v1, :flux} -> url
      {:v1, _} -> URL.append_query(url, query_payload)
    end
  end
end
