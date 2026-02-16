defmodule Membrane.Gemini.Integration.SimpleTest do
  use ExUnit.Case, async: false

  import Membrane.Testing.Assertions
  import Membrane.ChildrenSpec

  @input_audio_format %Membrane.RawAudio{
    channels: 1,
    sample_rate: 16_000,
    sample_format: :s16le
  }

  test "Gemini responds to a simple text prompt" do
    spec = [
      child(:audio_source, %Membrane.Testing.Source{
        stream_format: @input_audio_format,
        output: []
      })
      |> via_in(:in_audio)
      |> child(:gemini, %Membrane.Gemini.Bin{mode: :discrete})
      |> child(:sink, Membrane.Testing.Sink),
      child(:text_source, %Membrane.Testing.Source{
        output: ["Hello, world!"]
      })
      |> via_in(:in_text)
      |> get_child(:gemini)
    ]

    {:ok, _supervisor_pid, pipeline_pid} = Membrane.Testing.Pipeline.start(spec: spec)

    timeout_ms = 5_000
    assert_sink_event(pipeline_pid, :sink, %Membrane.Gemini.ResponseStartEvent{}, timeout_ms)
    assert_sink_event(pipeline_pid, :sink, %Membrane.Gemini.ThinkingEvent{}, timeout_ms)
    assert_sink_event(pipeline_pid, :sink, %Membrane.Gemini.OutputTranscriptEvent{}, timeout_ms)
    assert_sink_buffer(pipeline_pid, :sink, %Membrane.Buffer{}, timeout_ms)
    assert_sink_event(pipeline_pid, :sink, %Membrane.Gemini.ResponseEndEvent{}, timeout_ms)
    assert_end_of_stream(pipeline_pid, :sink, :input, timeout_ms)
  end

  # To regenerate fixture:
  # $ espeak-ng -v en-gb-scotland "Hello, world!" -w hello.wav
  # $ ffmpeg -i hello.wav -ar 16000 -f s16le -acodec pcm_s16le test/fixtures/hello.raw
  @hello_raw_audio "./test/fixtures/hello.raw"

  test "Gemini responds to a simple audio prompt" do
    # NOTE: `Membrane.Gemini.Bin` is aware that it sent a text prompt,
    # NOTE: but not an audio prompt, since it relies on the Live API server's
    # NOTE: VAD to detect if the user is speaking.
    # NOTE: This means an EOS can only be prevented from being sent
    # NOTE: and terminating the pipeline after the response starts being received.
    # NOTE: To avoid premature termination, we use a realtimer to enforce
    # NOTE: a steady stream from the testing source and pad the rest of the audio
    # NOTE: with silence for the VAD to kick in.

    silence_1s =
      Membrane.RawAudio.silence(@input_audio_format, Membrane.Time.second())

    test_buffers =
      [
        File.read!(@hello_raw_audio)
        | List.duplicate(silence_1s, 10)
      ]
      |> Enum.map(&%Membrane.Buffer{payload: &1})

    spec = [
      child(:audio_source, %Membrane.Testing.Source{
        stream_format: @input_audio_format,
        output: test_buffers
      })
      |> child(:parser, %Membrane.RawAudioParser{
        overwrite_pts?: true
      })
      |> child(:realtimer, Membrane.Realtimer)
      |> via_in(:in_audio)
      |> child(:gemini, %Membrane.Gemini.Bin{mode: :discrete})
      |> child(:sink, Membrane.Testing.Sink),
      child(:text_source, %Membrane.Testing.Source{output: []})
      |> via_in(:in_text)
      |> get_child(:gemini)
    ]

    {:ok, _supervisor_pid, pipeline_pid} = Membrane.Testing.Pipeline.start(spec: spec)

    timeout_ms = 15_000
    assert_sink_event(pipeline_pid, :sink, %Membrane.Gemini.InputTranscriptEvent{}, timeout_ms)
    assert_sink_event(pipeline_pid, :sink, %Membrane.Gemini.ResponseStartEvent{}, timeout_ms)
    assert_sink_event(pipeline_pid, :sink, %Membrane.Gemini.ThinkingEvent{}, timeout_ms)
    assert_sink_event(pipeline_pid, :sink, %Membrane.Gemini.OutputTranscriptEvent{}, timeout_ms)
    assert_sink_buffer(pipeline_pid, :sink, %Membrane.Buffer{}, timeout_ms)
    assert_sink_event(pipeline_pid, :sink, %Membrane.Gemini.ResponseEndEvent{}, timeout_ms)
    assert_end_of_stream(pipeline_pid, :sink, :input, timeout_ms)
  end
end
