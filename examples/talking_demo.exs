Mix.install([
  {:membrane_core, "~> 1.0"},
  {:membrane_portaudio_plugin, "~> 0.19.4"},
  {:membrane_gemini_plugin, path: Path.join(__DIR__, "..")}
])

Logger.configure(level: :info)

defmodule Gemini.Demo.TextSource do
  use Membrane.Source

  def_output_pad :output,
    accepted_format: %Membrane.RemoteStream{type: :bytestream},
    flow_control: :push

  @impl true
  def handle_init(_ctx, _opts) do
    source_pid = self()

    {:ok, _task_pid} =
      Task.start_link(fn ->
        IO.stream(:line)
        |> Stream.map(&String.trim/1)
        |> Stream.reject(&(&1 == ""))
        |> Stream.each(fn line -> send(source_pid, {:text, line}) end)
        |> Stream.run()
      end)

    {[], %{}}
  end

  @impl true
  def handle_playing(_ctx, state),
    do: {[stream_format: {:output, %Membrane.RemoteStream{type: :bytestream}}], state}

  @impl true
  def handle_info({:text, text}, _ctx, state),
    do: {[buffer: {:output, %Membrane.Buffer{payload: text}}], state}
end

defmodule Gemini.Demo.Mic.LivePipeline do
  use Membrane.Pipeline

  @impl true
  def handle_init(_ctx, _opts) do
    spec = [
      # audio source and sink
      child(:audio_source, %Membrane.PortAudio.Source{
        sample_format: :s16le,
        channels: 1,
        sample_rate: 16_000
      })
      |> via_in(:audio_input)
      |> child(:gemini, Membrane.Gemini.Bin)
      |> child(:transcript_printer, %Membrane.Debug.Filter{
        handle_event: fn
          %Membrane.Gemini.Events.Transcript{audio_origin: :client, text: text} ->
            Membrane.Logger.info("user  : #{inspect(text)}")

          %Membrane.Gemini.Events.Transcript{audio_origin: :server, text: text} ->
            Membrane.Logger.info("gemini: #{inspect(text)}")

          _other ->
            nil
        end
      })
      |> child(:gemini_speaker, %Membrane.PortAudio.Sink{
        ringbuffer_size: 32_768,
        portaudio_buffer_size: 512
      }),
      # text input for prompting
      child(:text_source, Gemini.Demo.TextSource)
      |> via_in(:text_input)
      |> get_child(:gemini)
    ]

    {[spec: spec], nil}
  end
end

Membrane.Pipeline.start_link(Gemini.Demo.Mic.LivePipeline, [])
Process.sleep(:infinity)
