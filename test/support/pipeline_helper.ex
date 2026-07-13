defmodule Membrane.Gemini.Test.PipelineHelper do
  @moduledoc false
  # Shared helpers for building test pipelines around `Membrane.Gemini.Bin`
  # and for making exact-ordering assertions on what reaches a
  # `Membrane.Testing.Sink`.

  import ExUnit.Assertions
  import Membrane.ChildrenSpec

  alias Membrane.Gemini.Test.PushSource
  alias Membrane.Testing

  @input_audio_format %Membrane.RawAudio{
    sample_format: :s16le,
    channels: 1,
    sample_rate: 16_000
  }

  @text_format %Membrane.RemoteStream{type: :bytestream}

  @spec input_audio_format() :: Membrane.RawAudio.t()
  def input_audio_format, do: @input_audio_format

  @doc """
  Standard bin-under-test spec: push-driven audio and text sources feeding
  `Membrane.Gemini.Bin`, output collected by a `Membrane.Testing.Sink`.
  """
  @spec bin_spec(:paced | :raw, Keyword.t(), Keyword.t()) :: [Membrane.ChildrenSpec.builder()]
  def bin_spec(mode, extra_opts, bin_opts \\ []) do
    bin = struct!(Membrane.Gemini.Bin, [mode: mode, extra_opts: extra_opts] ++ bin_opts)

    [
      child(:audio_src, %PushSource{stream_format: @input_audio_format})
      |> via_in(:audio_input)
      |> child(:gemini, bin)
      |> child(:sink, Testing.Sink),
      child(:text_src, %PushSource{stream_format: @text_format})
      |> via_in(:text_input)
      |> get_child(:gemini)
    ]
  end

  @spec push_audio(pid(), binary()) :: :ok
  def push_audio(pipeline, payload) do
    Testing.Pipeline.notify_child(
      pipeline,
      :audio_src,
      {:push, [buffer: {:output, %Membrane.Buffer{payload: payload}}]}
    )
  end

  @spec push_text(pid(), binary()) :: :ok
  def push_text(pipeline, text) do
    Testing.Pipeline.notify_child(
      pipeline,
      :text_src,
      {:push, [buffer: {:output, %Membrane.Buffer{payload: text}}]}
    )
  end

  @spec eos(pid(), :audio_src | :text_src) :: :ok
  def eos(pipeline, source) do
    Testing.Pipeline.notify_child(pipeline, source, {:push, [end_of_stream: :output]})
  end

  @doc """
  Pops the next buffer, event or end-of-stream notification the sink reported,
  skipping playback/stream-format/start-of-stream noise.

  Unlike `assert_sink_buffer/4` & co., which skip non-matching messages, this
  returns whatever came next, so consecutive calls assert exact ordering.
  """
  @spec pop_sink_payload(pid(), Membrane.Child.name(), non_neg_integer()) ::
          {:buffer, Membrane.Buffer.t()}
          | {:event, Membrane.Event.t()}
          | {:end_of_stream, Membrane.Pad.ref()}
  def pop_sink_payload(pipeline, sink \\ :sink, timeout \\ 2000) do
    assert_receive {Membrane.Testing.Pipeline, ^pipeline,
                    {:handle_child_notification, {payload, ^sink}}},
                   timeout

    case payload do
      {:buffer, _buffer} -> payload
      {:event, _event} -> payload
      {:end_of_stream, _pad} -> payload
      _other -> pop_sink_payload(pipeline, sink, timeout)
    end
  end
end
