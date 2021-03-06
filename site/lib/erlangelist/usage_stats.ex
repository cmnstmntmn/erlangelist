defmodule Erlangelist.UsageStats do
  use GenServer
  import EnvHelper

  def folder(), do: Erlangelist.db_path("usage_stats")

  def start_link(_) do
    init_config()
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  def report(key, value), do: GenServer.cast(__MODULE__, {:report, Date.utc_today(), key, value})

  @impl GenServer
  def init(_) do
    File.mkdir_p(folder())
    enqueue_cleanup()
    enqueue_flush()
    {:ok, initialize_state(Date.utc_today())}
  end

  @impl GenServer
  def handle_cast({:report, date, key, value}, state), do: {:noreply, store_report(state, date, key, value)}

  @impl GenServer
  def handle_info(:flush, state) do
    state = write_data(state)
    enqueue_flush()
    {:noreply, state}
  end

  def handle_info(:cleanup, state) do
    with {:ok, files} <- File.ls(folder()) do
      files
      |> Enum.sort()
      |> Enum.reverse()
      |> Enum.drop(setting!(:retention))
      |> Stream.map(&Path.join(folder(), &1))
      |> Enum.each(&File.rm/1)
    end

    enqueue_cleanup()

    {:noreply, state}
  end

  def handle_info(other, state), do: super(other, state)

  defp enqueue_flush(), do: Process.send_after(self(), :flush, setting!(:flush_interval))
  defp enqueue_cleanup(), do: Process.send_after(self(), :cleanup, setting!(:cleanup_interval))

  defp store_report(state, date, key, value) do
    state
    |> ensure_proper_data(date)
    |> update_in([:data], &add_histogram(&1, key, value, 1))
  end

  defp add_histogram(data, key, value, count) do
    data
    |> Map.put_new(key, %{})
    |> update_in([key], &Map.put_new(&1, value, 0))
    |> update_in([key, value], &(&1 + count))
  end

  defp ensure_proper_data(%{date: date} = state, date), do: state

  defp ensure_proper_data(state, date) do
    write_data(state)
    initialize_state(date)
  end

  defp initialize_state(date), do: %{date: date, data: %{}}

  defp stored_data(date) do
    try do
      date
      |> date_file()
      |> File.read!()
      |> :erlang.binary_to_term()
    catch
      _, _ -> %{}
    end
  end

  defp write_data(state) do
    case append_points(state.data) do
      [] ->
        state

      append_points ->
        data_to_store =
          Enum.reduce(append_points, stored_data(state.date), fn {key, value, count}, data ->
            add_histogram(data, key, value, count)
          end)

        File.write(date_file(state.date), :erlang.term_to_binary(data_to_store))
        Erlangelist.Backup.backup(folder())

        %{state | data: %{}}
    end
  end

  defp append_points(data) do
    for {key, histogram_data} <- data,
        {value, count} <- histogram_data,
        do: {key, value, count}
  end

  defp date_file(date), do: Path.join(folder(), Date.to_iso8601(date, :basic))

  defp setting!(name), do: Application.fetch_env!(:erlangelist, __MODULE__) |> Keyword.fetch!(name)
  defp init_config(), do: Application.put_env(:erlangelist, __MODULE__, config())

  defp config() do
    [
      flush_interval: env_specific(prod: :timer.minutes(1), else: :timer.seconds(1)),
      cleanup_interval: env_specific(prod: :timer.hours(1), else: :timer.minutes(1)),
      retention: 7
    ]
  end
end
