# dsp.rb

class DspVoice
    attr_accessor :brr_addr, :brr_offset, :pitch_counter,
                  :history0, :history1, :decoded_block,
                  :key_on, :key_off, :env_mode, :env_level,
                  :loop_flag, :end_flag, :out_sample, :kon_latched
  
    def initialize
      @brr_addr = 0
      @brr_offset = 16
      @pitch_counter = 0
      @history0 = 0
      @history1 = 0
      @decoded_block = Array.new(16, 0)
      @key_on = 0
      @key_off = 0
      @env_mode = ENV_RELEASE
      @env_level = 0
      @loop_flag = 0
      @end_flag = 0
      @out_sample = 0
      @kon_latched = 0
    end
  end
  
  ENV_OFF     = 0
  ENV_ATTACK  = 1
  ENV_DECAY   = 2
  ENV_SUSTAIN = 3
  ENV_RELEASE = 4
  
  class DSP
    COUNTER_RATES = [
      0, 2048, 1536, 1280, 1024, 768, 640, 512, 384, 320, 256, 192,
      160, 128, 96, 80, 64, 48, 40, 32, 24, 20, 16, 12, 10, 8, 6, 5, 4, 3, 2, 1
    ]
  
    attr_accessor :ram, :regs, :voices, :noise_lfsr, :global_counter
  
    def initialize(ram)
      @ram = ram
      @regs = Array.new(128, 0)
      @voices = Array.new(8) { DspVoice.new }
      @noise_lfsr = 0x4000
      @global_counter = 0
      reset
    end
  
    def reset
      @regs.fill(0)
      @voices.each do |v|
        v.pitch_counter = 0
        v.env_level = 0
        v.key_on = 0
        v.key_off = 0
        v.env_mode = ENV_RELEASE
        v.history0 = 0
        v.history1 = 0
        v.brr_offset = 16
        v.end_flag = 0
        v.kon_latched = 0
      end
    end
  
    def read(addr)
      @regs[addr & 0x7f]
    end
  
    def write(addr, val)
      addr &= 0x7f
      return if addr == 0x7c  # ENDX ignored
      @regs[addr] = val
    end
  
    # ---- register helpers ----
    def vol_l(v)  = signed(@regs[v * 0x10 + 0x00])
    def vol_r(v)  = signed(@regs[v * 0x10 + 0x01])
    def pitch(v)  = @regs[v * 0x10 + 0x02] | (@regs[v * 0x10 + 0x03] << 8)
    def srcn(v)   = @regs[v * 0x10 + 0x04]
    def adsr1(v)  = @regs[v * 0x10 + 0x05]
    def adsr2(v)  = @regs[v * 0x10 + 0x06]
    def gain(v)   = @regs[v * 0x10 + 0x07]
  
    def reg_kon   = @regs[0x4c]
    def reg_koff  = @regs[0x5c]
    def reg_pmon  = @regs[0x2d]
    def reg_non   = @regs[0x3d]
    def reg_dir   = @regs[0x5d]
    def reg_mvol_l = signed(@regs[0x0c])
    def reg_mvol_r = signed(@regs[0x1c])
  
    def signed(v)
      v >= 128 ? v - 256 : v
    end
  
    # ---- sample directory ----
    def sample_dir_entry(srcn_val)
      base = (reg_dir << 8) + srcn_val * 4
      start = @ram[base] | (@ram[base + 1] << 8)
      loop  = @ram[base + 2] | (@ram[base + 3] << 8)
      { start: start, loop: loop }
    end
  
    # ---- BRR decode ----
    def decode_brr_block(voice, addr)
      header = @ram[addr]
      range  = (header >> 4) & 0x0f
      filter = (header >> 2) & 0x03
      loop_bit = (header >> 1) & 1
      end_bit  = header & 1
  
      h1 = voice.history0
      h2 = voice.history1
  
      16.times do |i|
        byte = @ram[addr + 1 + (i >> 1)]
        nibble = (i.even? ? (byte >> 4) : (byte & 0x0f))
        nibble -= 16 if nibble >= 8
  
        sample =
          if range <= 12
            (nibble << range) >> 1
          else
            nibble < 0 ? -2048 : 0
          end
  
        pred = case filter
        when 0 then 0
        when 1 then h1 + ((-h1) >> 4)
        when 2 then h1 * 2 + ((-(h1 * 3)) >> 5) - h2 + (h2 >> 4)
        when 3 then h1 * 2 + ((-(h1 * 13)) >> 6) - h2 + ((h2 * 3) >> 4)
        end
  
        s = sample + pred
        s = [[s, -32768].max, 32767].min
  
        voice.decoded_block[i] = s
        h2 = h1
        h1 = s
      end
  
      voice.history0 = h1
      voice.history1 = h2
      voice.loop_flag = loop_bit == 1
      voice.end_flag  = end_bit == 1
  
      end_bit == 1
    end
  
    # ---- noise ----
    def step_noise
      lfsr = @noise_lfsr
      bit = ((lfsr << 14) ^ (lfsr << 13)) & 0x4000
      lfsr = ((lfsr >> 1) | bit) & 0x7fff
      @noise_lfsr = lfsr
      v = lfsr & 0x7fff
      v & 0x4000 != 0 ? v - 0x8000 : v
    end
  
    # ---- envelope ----
    def rate_fires(rate_index)
      period = COUNTER_RATES[rate_index] || 0
      return false if period == 0
      (@global_counter % period) == 0
    end
  
    def step_envelope(voice, idx)
      a1 = adsr1(idx)
      a2 = adsr2(idx)
      use_adsr = (a1 & 0x80) != 0
  
      voice.env_mode = ENV_RELEASE if voice.key_off
  
      case voice.env_mode
      when ENV_RELEASE
        voice.env_level -= 8
        voice.env_level = 0 if voice.env_level < 0
        return voice.env_level
      end
  
      if use_adsr
        attack_rate  = (a1 & 0x0f) * 2 + 1
        decay_rate   = ((a1 >> 4) & 0x07) * 2 + 16
        sustain_rate = a2 & 0x1f
        sustain_lvl  = (((a2 >> 5) & 0x07) + 1) * 256
  
        case voice.env_mode
        when ENV_ATTACK
          if rate_fires(attack_rate)
            voice.env_level += (attack_rate == 31 ? 1024 : 32)
            if voice.env_level >= 2047
              voice.env_level = 2047
              voice.env_mode = ENV_DECAY
            end
          end
  
        when ENV_DECAY
          if rate_fires(decay_rate)
            voice.env_level -= (((voice.env_level - 1) >> 8) + 1)
            voice.env_level = 0 if voice.env_level < 0
            voice.env_mode = ENV_SUSTAIN if voice.env_level <= sustain_lvl
          end
  
        when ENV_SUSTAIN
          if sustain_rate > 0 && rate_fires(sustain_rate)
            voice.env_level -= (((voice.env_level - 1) >> 8) + 1)
            voice.env_level = 0 if voice.env_level < 0
          end
        end
  
      else
        gain_val = gain(idx)
        if (gain_val & 0x80) == 0
          voice.env_level = (gain_val & 0x7f) * 16
        else
          mode = (gain_val >> 5) & 0x03
          rate = gain_val & 0x1f
          if rate_fires(rate)
            case mode
            when 0 then voice.env_level -= 32
            when 1 then voice.env_level += 32
            when 2 then voice.env_level -= (((voice.env_level - 1) >> 8) + 1)
            when 3 then voice.env_level += (voice.env_level < 1536 ? 32 : 8)
            end
            voice.env_level = [[voice.env_level, 0].max, 2047].min
          end
        end
      end
  
      voice.env_level = [[voice.env_level, 0].max, 2047].min
      voice.env_level
    end
  
    # ---- key on ----
    def trigger_key_on(voice, idx)
      e = sample_dir_entry(srcn(idx))
      voice.brr_addr = e[:start]
      voice.brr_offset = 16
      voice.pitch_counter = 0
      voice.history0 = 0
      voice.history1 = 0
      voice.env_level = 0
      voice.env_mode = ENV_ATTACK
      voice.key_off = 0
      voice.end_flag = 0
      voice.loop_flag = 0
    end
  
    # ---- main sample generator ----
    def generate_sample
      @global_counter += 1
  
      mix_l = 0.0
      mix_r = 0.0
  
      kon = reg_kon
      koff = reg_koff
  
      @voices.each_with_index do |voice, i|
        bit = 1 << i
  
        if (kon & bit) != 0
          unless voice.kon_latched
            trigger_key_on(voice, i)
            voice.kon_latched = 1
          end
        else
          voice.kon_latched = 0
        end
  
        voice.key_off = (koff & bit) != 0
  
        next if voice.env_mode == ENV_OFF
  
        p = pitch(i)
        if i > 0 && (reg_pmon & bit) != 0
          prev_out = @voices[i - 1].out_sample
          p = (p * ((prev_out >> 5) + 1024)) / 1024
        end
        p = 0x3fff if p > 0x3fff
  
        if voice.brr_offset >= 16
          if voice.end_flag
            if voice.loop_flag
              e = sample_dir_entry(srcn(i))
              voice.brr_addr = e[:loop]
            else
              voice.env_mode = ENV_OFF
              voice.env_level = 0
              next
            end
          end
          decode_brr_block(voice, voice.brr_addr)
          voice.brr_offset = 0
        end
  
        idx = voice.brr_offset
        s0 = voice.decoded_block[idx]
        s1 = idx < 15 ? voice.decoded_block[idx + 1] : s0
        frac = (voice.pitch_counter & 0xfff) / 4096.0
        sample = s0 + (s1 - s0) * frac
  
        sample = step_noise if (reg_non & bit) != 0
  
        env = step_envelope(voice, i)
        sample = sample * env / 2047.0
  
        voice.out_sample = sample.to_i
  
        mix_l += sample * (vol_l(i) / 128.0)
        mix_r += sample * (vol_r(i) / 128.0)
  
        voice.pitch_counter += p
        advance = voice.pitch_counter >> 12
        voice.pitch_counter &= 0xfff
        voice.brr_offset += advance
  
        while voice.brr_offset >= 16
          if voice.end_flag
            if voice.loop_flag
              e = sample_dir_entry(srcn(i))
              voice.brr_addr = e[:loop]
            else
              voice.env_mode = ENV_OFF
              voice.env_level = 0
              voice.brr_offset = 16
              break
            end
          else
            voice.brr_addr = (voice.brr_addr + 9) & 0xffff
          end
  
          break if voice.env_mode == ENV_OFF
  
          decode_brr_block(voice, voice.brr_addr)
          voice.brr_offset -= 16
        end
      end
  
      out_l = Math.tanh(mix_l * reg_mvol_l / (128.0 * 8192.0))
      out_r = Math.tanh(mix_r * reg_mvol_r / (128.0 * 8192.0))
  
      [out_l, out_r]
    end
  end
  