require "spc700.rb"
require "dsp.rb"
# main.rb
SDSP_SAMPLE_RATE = 32000
CPU_CYCLES_PER_SAMPLE = 32
class SpcEngine
    attr_accessor :dsp, :cpu, :loaded, :cycle_accum
  
    def initialize(dsp: nil, cpu: nil, loaded: 0, cycle_accum: 0)
      @dsp = dsp
      @cpu = cpu
      @loaded = loaded
      @cycle_accum = cycle_accum
    end
end
def engine_load(eng,parsed)
    dsp_init(eng.dsp, eng.cpu.ram)
    spc700_init(eng.cpu, eng.dsp)
end
def engine_render_sample(eng,outL,outR) 
    
end
#くそコード注意
SDSP_SAMPLE_RATE = 32000 unless defined?(SDSP_SAMPLE_RATE)

def print_usage(prog_name)
  $stderr.puts "Usage: #{prog_name} [options] <input.spc> <output.wav>"
  $stderr.puts "Options:"
  $stderr.puts "  -h, --help           ヘルプを表示"
  $stderr.puts "  --duration <sec>     再生時間（秒, デフォルト: 180）"
  $stderr.puts "  --fade <sec>         フェードアウト時間（秒, デフォルト: 5）"
  $stderr.puts "  --rate <rate>        出力サンプルレート（Hz, デフォルト: 44100）"
  $stderr.puts "  --no-resample        オリジナルレート (32000Hz) で出力"
end

def clamp_s16(val)
  v = val.round
  return -32768 if v < -32768
  return 32767 if v > 32767
  v
end

class WavWriter
  def initialize(path, sample_rate, channels = 2, bits_per_sample = 16)
    @file = File.open(path, 'wb')
    @sample_rate = sample_rate
    @channels = channels
    @bits_per_sample = bits_per_sample
    @data_size = 0
    write_header(0)
  end

  def write_s16(samples)
    packed = samples.pack('s*')
    @file.write(packed)
    @data_size += packed.bytesize
  end

  def close
    return unless @file

    @file.seek(0, IO::SEEK_SET)
    write_header(@data_size)
    @file.close
    @file = nil
  end

  private

  def write_header(data_size)
    byte_rate = @sample_rate * @channels * (@bits_per_sample / 8)
    block_align = @channels * (@bits_per_sample / 8)
    header = [
      'RIFF',
      36 + data_size,
      'WAVE',
      'fmt ',
      16,
      1,  # AudioFormat (PCM)
      @channels,
      @sample_rate,
      byte_rate,
      block_align,
      @bits_per_sample,
      'data',
      data_size
    ].pack('a4Va4a4VvvVVvva4V')
    @file.write(header)
  end
end

def main(argv = ARGV)
  if argv.length < 2
    print_usage($0)
    return 1
  end

  in_path = nil
  out_path = nil
  duration_sec = 180.0
  fade_sec = 5.0
  out_rate = 44100
  no_resample = false

  i = 0
  while i < argv.length
    arg = argv[i]
    case arg
    when '-h', '--help'
      print_usage($0)
      return 0
    when '--duration'
      i += 1
      duration_sec = argv[i].to_f if i < argv.length
    when '--fade'
      i += 1
      fade_sec = argv[i].to_f if i < argv.length
    when '--rate'
      i += 1
      out_rate = argv[i].to_i if i < argv.length
    when '--no-resample'
      no_resample = true
    else
      if in_path.nil?
        in_path = arg
      elsif out_path.nil?
        out_path = arg
      else
        $stderr.puts "不明な引数: #{arg}"
        print_usage($0)
        return 1
      end
    end
    i += 1
  end

  if in_path.nil? || out_path.nil?
    print_usage($0)
    return 1
  end

  out_rate = SDSP_SAMPLE_RATE if no_resample

  if out_rate <= 0
    $stderr.puts 'エラー: 不正なサンプルレートです'
    return 1
  end

  if duration_sec <= 0
    $stderr.puts 'エラー: 不正な再生時間です'
    return 1
  end

  fade_sec = 0.0 if fade_sec < 0

  begin
    filebuf = File.binread(in_path)
  rescue StandardError
    $stderr.puts "エラー: ファイルを開けません: #{in_path}"
    return 1
  end

  if filebuf.bytesize.zero?
    $stderr.puts "エラー: ファイルサイズが不正です: #{in_path}"
    return 1
  end

  parsed = SpcParsed.new
  errbuf = ''
  if respond_to?(:parse_spc) && parse_spc(filebuf, filebuf.bytesize, parsed, errbuf) != 0
    $stderr.puts "エラー: #{errbuf}"
    return 1
  end

  song_title = (parsed.respond_to?(:song_title) && !parsed.song_title.to_s.empty?) ? parsed.song_title : '(不明)'
  $stderr.puts "曲名: #{song_title}"
  $stderr.puts "ゲーム: #{parsed.game_title}" if parsed.respond_to?(:game_title) && !parsed.game_title.to_s.empty?
  $stderr.puts "作曲: #{parsed.artist}" if parsed.respond_to?(:artist) && !parsed.artist.to_s.empty?
  $stderr.puts "Dump: #{parsed.dumper_name}" if parsed.respond_to?(:dumper_name) && !parsed.dumper_name.to_s.empty?

  eng = SpcEngine.new
  eng.load(parsed) if eng.respond_to?(:load)

  begin
    wav = WavWriter.new(out_path, out_rate, 2, 16)
  rescue StandardError
    $stderr.puts "エラー: 出力ファイルを開けません: #{out_path}"
    return 1
  end

  total_out_frames = (duration_sec * out_rate).round
  fade_out_frames = (fade_sec * out_rate).round
  fade_out_frames = total_out_frames if fade_out_frames > total_out_frames
  fade_start_frame = total_out_frames - fade_out_frames

  resample_ratio = SDSP_SAMPLE_RATE.to_f / out_rate.to_f
  src_pos = 0.0

  # 最初の2サンプルを取得
  prev_l, prev_r = eng.render_sample
  next_l, next_r = eng.render_sample

  block_size = 4096
  out_buf = []

  total_out_frames.times do |frame|
    while src_pos >= 1.0
      prev_l, prev_r = next_l, next_r
      next_l, next_r = eng.render_sample
      src_pos -= 1.0
    end

    frac = src_pos
    l = prev_l + (next_l - prev_l) * frac
    r = prev_r + (next_r - prev_r) * frac
    src_pos += resample_ratio

    gain = 1.0
    if fade_out_frames > 0 && frame >= fade_start_frame
      t = (frame - fade_start_frame).to_f / fade_out_frames
      t = 1.0 if t > 1.0
      gain = 1.0 - t
    end

    out_buf << clamp_s16(l * gain)
    out_buf << clamp_s16(r * gain)

    if out_buf.length >= block_size * 2
      wav.write_s16(out_buf)
      out_buf.clear
    end
  end

  wav.write_s16(out_buf) unless out_buf.empty?
  wav.close

  $stderr.puts format('完了: %s (%.1f秒, %dHz)', out_path, duration_sec, out_rate)
  0
end

main if __FILE__ == $0