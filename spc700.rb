class SPC700
    PERIODS = [128, 128, 16].freeze
  
    attr_accessor :dsp, :ram, :a, :x, :y, :sp, :pc,
                  :flag_n, :flag_v, :flag_p, :flag_b, :flag_h, :flag_i, :flag_z, :flag_c,
                  :io_in, :io_out, :timer_enable, :timer_target, :timer_counter, :timer_out,
                  :cycles, :t_accum, :stopped
  
    def initialize(dsp = nil)
      @dsp = dsp
      @ram = Array.new(0x10000, 0)
  
      @a = 0
      @x = 0
      @y = 0
      @sp = 0
      @pc = 0
  
      @flag_n = 0
      @flag_v = 0
      @flag_p = 0
      @flag_b = 0
      @flag_h = 0
      @flag_i = 0
      @flag_z = 0
      @flag_c = 0
  
      @io_in = Array.new(4, 0)
      @io_out = Array.new(4, 0)
      @timer_enable = Array.new(3, 0)
      @timer_target = Array.new(3, 0)
      @timer_counter = Array.new(3, 0)
      @timer_out = Array.new(3, 0)
      @cycles = 0
  
      @t_accum = Array.new(3, 0)
      @stopped = false
    end
  
    def read_timer_out(t)
      v = @timer_out[t] & 0x0f
      @timer_out[t] = 0
      v
    end
    
      
    def read(addr)
      addr &= 0xffff
      case addr
      when 0xf2
        @dsp ? (@dsp.reg_addr & 0xff) : 0
      when 0xf3
        @dsp ? @dsp.read(@dsp.reg_addr & 0xff) : 0
      when 0xf4..0xf7
        @io_in[addr - 0xf4]
      when 0xfd then read_timer_out(0)
      when 0xfe then read_timer_out(1)
      when 0xff then read_timer_out(2)
      else
        @ram[addr]
      end
    end
  
    def write(addr, val)
      addr &= 0xffff
      val &= 0xff
      case addr
      when 0xf1
        3.times do |t|
          en = (val >> t) & 1
          if en != 0 && @timer_enable[t].zero?
            @timer_counter[t] = 0
            @timer_out[t] = 0
          end
          @timer_enable[t] = en
        end
        @ram[addr] = val
      when 0xf2
        @dsp.reg_addr = val if @dsp
        @ram[addr] = val
      when 0xf3
        @dsp.write(@dsp.reg_addr & 0xff, val) if @dsp
        @ram[addr] = val
      when 0xf4..0xf7
        @io_out[addr - 0xf4] = val
        @ram[addr] = val
      when 0xfa
        @timer_target[0] = val.zero? ? 256 : val
        @ram[addr] = val
      when 0xfb
        @timer_target[1] = val.zero? ? 256 : val
        @ram[addr] = val
      when 0xfc
        @timer_target[2] = val.zero? ? 256 : val
        @ram[addr] = val
      else
        @ram[addr] = val
      end
    end
  
    def tick_timers(cyc)
      3.times do |t|
        next if @timer_enable[t].zero?
  
        @t_accum[t] += cyc
        while @t_accum[t] >= PERIODS[t]
          @t_accum[t] -= PERIODS[t]
          @timer_counter[t] += 1
          if @timer_counter[t] >= @timer_target[t]
            @timer_counter[t] = 0
            @timer_out[t] = (@timer_out[t] + 1) & 0x0f
          end
        end
      end
    end
  
    def psw
      (@flag_n << 7) | (@flag_v << 6) | (@flag_p << 5) |
        (@flag_b << 4) | (@flag_h << 3) | (@flag_i << 2) |
        (@flag_z << 1) | @flag_c
    end
    
    def psw=(v)
      v &= 0xff
      @flag_n = (v >> 7) & 1
      @flag_v = (v >> 6) & 1
      @flag_p = (v >> 5) & 1
      @flag_b = (v >> 4) & 1
      @flag_h = (v >> 3) & 1
      @flag_i = (v >> 2) & 1
      @flag_z = (v >> 1) & 1
      @flag_c = v & 1
    end
  
    def dp_base
      @flag_p != 0 ? 0x100 : 0x000
    end
  
    def dpaddr(off)
      (dp_base + off) & 0xffff
    end
  
    def set_nz8(v)
      v &= 0xff
      @flag_z = v.zero? ? 1 : 0
      @flag_n = (v & 0x80) != 0 ? 1 : 0
      v
    end
  
    def push8(v)
      @ram[0x100 + @sp] = v & 0xff
      @sp = (@sp - 1) & 0xff
    end
  
    def pop8
      @sp = (@sp + 1) & 0xff
      @ram[0x100 + @sp]
    end
  
    def push16(v)
      push8((v >> 8) & 0xff)
      push8(v & 0xff)
    end
  
    def pop16
      lo = pop8
      hi = pop8
      (hi << 8) | lo
    end
  
    def fetch8
      v = read(@pc)
      @pc = (@pc + 1) & 0xffff
      v
    end
  
    def fetch16
      lo = fetch8
      hi = fetch8
      (hi << 8) | lo
    end
  
    def adc(a, b, carry_in)
      result = a + b + carry_in
      @flag_h = (((a & 0xf) + (b & 0xf) + carry_in) > 0xf) ? 1 : 0
      @flag_c = result > 0xff ? 1 : 0
      r8 = result & 0xff
      @flag_v = ((~(a ^ b) & (a ^ r8) & 0x80) != 0) ? 1 : 0
      set_nz8(r8)
      r8
    end
  
    def sbc(a, b, carry_in)
      adc(a, (~b) & 0xff, carry_in)
    end
  
    def do_branch(cond, disp)
      if cond
        s = (disp & 0x80) != 0 ? disp - 256 : disp
        @pc = (@pc + s) & 0xffff
        2
      else
        0
      end
    end
  
    def do_asl(v)
      c = (v & 0x80) != 0 ? 1 : 0
      r = (v << 1) & 0xff
      @flag_c = c
      set_nz8(r)
    end
  
    def do_lsr(v)
      c = v & 1
      r = (v >> 1) & 0xff
      @flag_c = c
      set_nz8(r)
    end
  
    def do_rol(v)
      c = (v & 0x80) != 0 ? 1 : 0
      r = ((v << 1) | @flag_c) & 0xff
      @flag_c = c
      set_nz8(r)
    end
  
    def do_ror(v)
      c = v & 1
      r = ((v >> 1) | (@flag_c << 7)) & 0xff
      @flag_c = c
      set_nz8(r)
    end
  
    def step
      op = fetch8
      cyc = exec_op(op)
      @cycles += cyc
      tick_timers(cyc)
      cyc
    end
  
    private
  
    def exec_op(op)
      case op
      when 0x00 then 2 # NOP
  
      when 0xE8 then @a = set_nz8(fetch8); 2
      when 0xCD then @x = set_nz8(fetch8); 2
      when 0x8D then @y = set_nz8(fetch8); 2
  
      when 0x7D then @a = set_nz8(@x); 2
      when 0xDD then @a = set_nz8(@y); 2
      when 0x5D then @x = set_nz8(@a); 2
      when 0xFD then @y = set_nz8(@a); 2
      when 0x9D then @x = set_nz8(@sp); 2
      when 0xBD then @sp = @x; 2
  
      when 0xC4 then write(dpaddr(fetch8), @a); 4
      when 0xE4 then @a = set_nz8(read(dpaddr(fetch8))); 3
      when 0xD8 then write(dpaddr(fetch8), @x); 4
      when 0xF8 then @x = set_nz8(read(dpaddr(fetch8))); 3
      when 0xCB then write(dpaddr(fetch8), @y); 4
      when 0xEB then @y = set_nz8(read(dpaddr(fetch8))); 3
  
      when 0xD4 then write(dpaddr((fetch8 + @x) & 0xff), @a); 5
      when 0xF4 then @a = set_nz8(read(dpaddr((fetch8 + @x) & 0xff))); 4
      when 0xD9 then write(dpaddr((fetch8 + @y) & 0xff), @x); 5
      when 0xF9 then @x = set_nz8(read(dpaddr((fetch8 + @y) & 0xff))); 4
      when 0xDB then write(dpaddr((fetch8 + @x) & 0xff), @y); 5
      when 0xFB then @y = set_nz8(read(dpaddr((fetch8 + @x) & 0xff))); 4
  
      when 0xC5 then write(fetch16, @a); 5
      when 0xE5 then @a = set_nz8(read(fetch16)); 4
      when 0xC9 then write(fetch16, @x); 5
      when 0xE9 then @x = set_nz8(read(fetch16)); 4
      when 0xCC then write(fetch16, @y); 5
      when 0xEC then @y = set_nz8(read(fetch16)); 4
  
      when 0xD5 then write((fetch16 + @x) & 0xffff, @a); 6
      when 0xD6 then write((fetch16 + @y) & 0xffff, @a); 6
      when 0xF5 then @a = set_nz8(read((fetch16 + @x) & 0xffff)); 5
      when 0xF6 then @a = set_nz8(read((fetch16 + @y) & 0xffff)); 5
  
      when 0xC6 then write(dpaddr(@x), @a); 4
      when 0xE6 then @a = set_nz8(read(dpaddr(@x))); 3
      when 0xAF then write(dpaddr(@x), @a); @x = (@x + 1) & 0xff; 4
      when 0xBF then @a = set_nz8(read(dpaddr(@x))); @x = (@x + 1) & 0xff; 4
  
      when 0xC7
        ptr = dpaddr((fetch8 + @x) & 0xff)
        a = read(ptr) | (read((ptr + 1) & 0xffff) << 8)
        write(a, @a); 7
      when 0xE7
        ptr = dpaddr((fetch8 + @x) & 0xff)
        a = read(ptr) | (read((ptr + 1) & 0xffff) << 8)
        @a = set_nz8(read(a)); 6
      when 0xD7
        ptr = dpaddr(fetch8)
        base = read(ptr) | (read((ptr + 1) & 0xffff) << 8)
        write((base + @y) & 0xffff, @a); 7
      when 0xF7
        ptr = dpaddr(fetch8)
        base = read(ptr) | (read((ptr + 1) & 0xffff) << 8)
        @a = set_nz8(read((base + @y) & 0xffff)); 6
  
      when 0xFA then src = dpaddr(fetch8); dst = dpaddr(fetch8); write(dst, read(src)); 5
      when 0x8F then v = fetch8; a = dpaddr(fetch8); write(a, v); 5
  
      when 0xBA
        a = dpaddr(fetch8)
        lo = read(a)
        hi = read((a + 1) & 0xffff)
        @a = lo; @y = hi
        w = (hi << 8) | lo
        @flag_z = w.zero? ? 1 : 0
        @flag_n = (hi & 0x80) != 0 ? 1 : 0
        5
      when 0xDA
        a = dpaddr(fetch8)
        write(a, @a)
        write((a + 1) & 0xffff, @y)
        5
      when 0x3A
        a = dpaddr(fetch8)
        w = read(a) | (read((a + 1) & 0xffff) << 8)
        w = (w + 1) & 0xffff
        write(a, w & 0xff)
        write((a + 1) & 0xffff, (w >> 8) & 0xff)
        @flag_z = w.zero? ? 1 : 0
        @flag_n = (w & 0x8000) != 0 ? 1 : 0
        6
      when 0x1A
        a = dpaddr(fetch8)
        w = read(a) | (read((a + 1) & 0xffff) << 8)
        w = (w - 1) & 0xffff
        write(a, w & 0xff)
        write((a + 1) & 0xffff, (w >> 8) & 0xff)
        @flag_z = w.zero? ? 1 : 0
        @flag_n = (w & 0x8000) != 0 ? 1 : 0
        6
      when 0x7A
        a = dpaddr(fetch8)
        ya = (@y << 8) | @a
        m = read(a) | (read((a + 1) & 0xffff) << 8)
        result = ya + m
        @flag_c = result > 0xffff ? 1 : 0
        r16 = result & 0xffff
        @flag_v = ((~(ya ^ m) & (ya ^ r16) & 0x8000) != 0) ? 1 : 0
        @flag_h = (((ya & 0xfff) + (m & 0xfff)) > 0xfff) ? 1 : 0
        @y = (r16 >> 8) & 0xff
        @a = r16 & 0xff
        @flag_z = r16.zero? ? 1 : 0
        @flag_n = (r16 & 0x8000) != 0 ? 1 : 0
        5
      when 0x9A
        a = dpaddr(fetch8)
        ya = (@y << 8) | @a
        m = read(a) | (read((a + 1) & 0xffff) << 8)
        m_inv = (~m) & 0xffff
        result = ya + m_inv + 1
        @flag_c = result > 0xffff ? 1 : 0
        r16 = result & 0xffff
        @flag_v = ((~(ya ^ m_inv) & (ya ^ r16) & 0x8000) != 0) ? 1 : 0
        @flag_h = (((ya & 0xfff) + (m_inv & 0xfff) + 1) > 0xfff) ? 1 : 0
        @y = (r16 >> 8) & 0xff
        @a = r16 & 0xff
        @flag_z = r16.zero? ? 1 : 0
        @flag_n = (r16 & 0x8000) != 0 ? 1 : 0
        5
      when 0x5A
        a = dpaddr(fetch8)
        ya = (@y << 8) | @a
        m = read(a) | (read((a + 1) & 0xffff) << 8)
        result = (ya - m) & 0xffff
        @flag_c = ya >= m ? 1 : 0
        @flag_z = result.zero? ? 1 : 0
        @flag_n = (result & 0x8000) != 0 ? 1 : 0
        4
  
      when 0x08 then @a = set_nz8(@a | fetch8); 2
      when 0x28 then @a = set_nz8(@a & fetch8); 2
      when 0x48 then @a = set_nz8(@a ^ fetch8); 2
      when 0x68 then v = fetch8; @flag_c = @a >= v ? 1 : 0; set_nz8((@a - v) & 0x1ff); 2
      when 0x88 then @a = adc(@a, fetch8, @flag_c); 2
      when 0xA8 then @a = sbc(@a, fetch8, @flag_c); 2
  
      when 0x04 then v = read(dpaddr(fetch8)); @a = set_nz8(@a | v); 3
      when 0x24 then v = read(dpaddr(fetch8)); @a = set_nz8(@a & v); 3
      when 0x44 then v = read(dpaddr(fetch8)); @a = set_nz8(@a ^ v); 3
      when 0x64 then v = read(dpaddr(fetch8)); @flag_c = @a >= v ? 1 : 0; set_nz8((@a - v) & 0x1ff); 3
      when 0x84 then v = read(dpaddr(fetch8)); @a = adc(@a, v, @flag_c); 3
      when 0xA4 then v = read(dpaddr(fetch8)); @a = sbc(@a, v, @flag_c); 3
  
      when 0x14 then v = read(dpaddr((fetch8 + @x) & 0xff)); @a = set_nz8(@a | v); 4
      when 0x34 then v = read(dpaddr((fetch8 + @x) & 0xff)); @a = set_nz8(@a & v); 4
      when 0x54 then v = read(dpaddr((fetch8 + @x) & 0xff)); @a = set_nz8(@a ^ v); 4
      when 0x74 then v = read(dpaddr((fetch8 + @x) & 0xff)); @flag_c = @a >= v ? 1 : 0; set_nz8((@a - v) & 0x1ff); 4
      when 0x94 then v = read(dpaddr((fetch8 + @x) & 0xff)); @a = adc(@a, v, @flag_c); 4
      when 0xB4 then v = read(dpaddr((fetch8 + @x) & 0xff)); @a = sbc(@a, v, @flag_c); 4
  
      when 0x05 then v = read(fetch16); @a = set_nz8(@a | v); 4
      when 0x25 then v = read(fetch16); @a = set_nz8(@a & v); 4
      when 0x45 then v = read(fetch16); @a = set_nz8(@a ^ v); 4
      when 0x65 then v = read(fetch16); @flag_c = @a >= v ? 1 : 0; set_nz8((@a - v) & 0x1ff); 4
      when 0x85 then v = read(fetch16); @a = adc(@a, v, @flag_c); 4
      when 0xA5 then v = read(fetch16); @a = sbc(@a, v, @flag_c); 4
  
      when 0x15 then v = read((fetch16 + @x) & 0xffff); @a = set_nz8(@a | v); 5
      when 0x16 then v = read((fetch16 + @y) & 0xffff); @a = set_nz8(@a | v); 5
      when 0x35 then v = read((fetch16 + @x) & 0xffff); @a = set_nz8(@a & v); 5
      when 0x36 then v = read((fetch16 + @y) & 0xffff); @a = set_nz8(@a & v); 5
      when 0x55 then v = read((fetch16 + @x) & 0xffff); @a = set_nz8(@a ^ v); 5
      when 0x56 then v = read((fetch16 + @y) & 0xffff); @a = set_nz8(@a ^ v); 5
      when 0x75 then v = read((fetch16 + @x) & 0xffff); @flag_c = @a >= v ? 1 : 0; set_nz8((@a - v) & 0x1ff); 5
      when 0x76 then v = read((fetch16 + @y) & 0xffff); @flag_c = @a >= v ? 1 : 0; set_nz8((@a - v) & 0x1ff); 5
      when 0x95 then v = read((fetch16 + @x) & 0xffff); @a = adc(@a, v, @flag_c); 5
      when 0x96 then v = read((fetch16 + @y) & 0xffff); @a = adc(@a, v, @flag_c); 5
      when 0xB5 then v = read((fetch16 + @x) & 0xffff); @a = sbc(@a, v, @flag_c); 5
      when 0xB6 then v = read((fetch16 + @y) & 0xffff); @a = sbc(@a, v, @flag_c); 5
  
      when 0x06 then v = read(dpaddr(@x)); @a = set_nz8(@a | v); 3
      when 0x26 then v = read(dpaddr(@x)); @a = set_nz8(@a & v); 3
      when 0x46 then v = read(dpaddr(@x)); @a = set_nz8(@a ^ v); 3
      when 0x66 then v = read(dpaddr(@x)); @flag_c = @a >= v ? 1 : 0; set_nz8((@a - v) & 0x1ff); 3
      when 0x86 then v = read(dpaddr(@x)); @a = adc(@a, v, @flag_c); 3
      when 0xA6 then v = read(dpaddr(@x)); @a = sbc(@a, v, @flag_c); 3
  
      when 0x07
        ptr = dpaddr((fetch8 + @x) & 0xff)
        a = read(ptr) | (read((ptr + 1) & 0xffff) << 8)
        @a = set_nz8(@a | read(a)); 6
      when 0x27
        ptr = dpaddr((fetch8 + @x) & 0xff)
        a = read(ptr) | (read((ptr + 1) & 0xffff) << 8)
        @a = set_nz8(@a & read(a)); 6
      when 0x47
        ptr = dpaddr((fetch8 + @x) & 0xff)
        a = read(ptr) | (read((ptr + 1) & 0xffff) << 8)
        @a = set_nz8(@a ^ read(a)); 6
      when 0x67
        ptr = dpaddr((fetch8 + @x) & 0xff)
        a = read(ptr) | (read((ptr + 1) & 0xffff) << 8)
        v = read(a)
        @flag_c = @a >= v ? 1 : 0
        set_nz8((@a - v) & 0x1ff); 6
      when 0x87
        ptr = dpaddr((fetch8 + @x) & 0xff)
        a = read(ptr) | (read((ptr + 1) & 0xffff) << 8)
        @a = adc(@a, read(a), @flag_c); 6
      when 0xA7
        ptr = dpaddr((fetch8 + @x) & 0xff)
        a = read(ptr) | (read((ptr + 1) & 0xffff) << 8)
        @a = sbc(@a, read(a), @flag_c); 6
  
      when 0x17
        ptr = dpaddr(fetch8)
        base = read(ptr) | (read((ptr + 1) & 0xffff) << 8)
        @a = set_nz8(@a | read((base + @y) & 0xffff)); 6
      when 0x37
        ptr = dpaddr(fetch8)
        base = read(ptr) | (read((ptr + 1) & 0xffff) << 8)
        @a = set_nz8(@a & read((base + @y) & 0xffff)); 6
      when 0x57
        ptr = dpaddr(fetch8)
        base = read(ptr) | (read((ptr + 1) & 0xffff) << 8)
        @a = set_nz8(@a ^ read((base + @y) & 0xffff)); 6
      when 0x77
        ptr = dpaddr(fetch8)
        base = read(ptr) | (read((ptr + 1) & 0xffff) << 8)
        v = read((base + @y) & 0xffff)
        @flag_c = @a >= v ? 1 : 0
        set_nz8((@a - v) & 0x1ff); 6
      when 0x97
        ptr = dpaddr(fetch8)
        base = read(ptr) | (read((ptr + 1) & 0xffff) << 8)
        @a = adc(@a, read((base + @y) & 0xffff), @flag_c); 6
      when 0xB7
        ptr = dpaddr(fetch8)
        base = read(ptr) | (read((ptr + 1) & 0xffff) << 8)
        @a = sbc(@a, read((base + @y) & 0xffff), @flag_c); 6
  
      when 0x09 then src = dpaddr(fetch8); dst = dpaddr(fetch8); write(dst, set_nz8(read(dst) | read(src))); 6
      when 0x29 then src = dpaddr(fetch8); dst = dpaddr(fetch8); write(dst, set_nz8(read(dst) & read(src))); 6
      when 0x49 then src = dpaddr(fetch8); dst = dpaddr(fetch8); write(dst, set_nz8(read(dst) ^ read(src))); 6
      when 0x69 then src = dpaddr(fetch8); dst = dpaddr(fetch8); va = read(dst); vb = read(src); @flag_c = va >= vb ? 1 : 0; set_nz8((va - vb) & 0x1ff); 6
      when 0x89 then src = dpaddr(fetch8); dst = dpaddr(fetch8); write(dst, adc(read(dst), read(src), @flag_c)); 6
      when 0xA9 then src = dpaddr(fetch8); dst = dpaddr(fetch8); write(dst, sbc(read(dst), read(src), @flag_c)); 6
  
      when 0x18 then v = fetch8; a = dpaddr(fetch8); write(a, set_nz8(read(a) | v)); 5
      when 0x38 then v = fetch8; a = dpaddr(fetch8); write(a, set_nz8(read(a) & v)); 5
      when 0x58 then v = fetch8; a = dpaddr(fetch8); write(a, set_nz8(read(a) ^ v)); 5
      when 0x78 then v = fetch8; a = dpaddr(fetch8); m = read(a); @flag_c = m >= v ? 1 : 0; set_nz8((m - v) & 0x1ff); 5
      when 0x98 then v = fetch8; a = dpaddr(fetch8); write(a, adc(read(a), v, @flag_c)); 5
      when 0xB8 then v = fetch8; a = dpaddr(fetch8); write(a, sbc(read(a), v, @flag_c)); 5
  
      when 0x19 then dst_a = dpaddr(@x); src_a = dpaddr(@y); write(dst_a, set_nz8(read(dst_a) | read(src_a))); 5
      when 0x39 then dst_a = dpaddr(@x); src_a = dpaddr(@y); write(dst_a, set_nz8(read(dst_a) & read(src_a))); 5
      when 0x59 then dst_a = dpaddr(@x); src_a = dpaddr(@y); write(dst_a, set_nz8(read(dst_a) ^ read(src_a))); 5
      when 0x79 then dst_a = dpaddr(@x); src_a = dpaddr(@y); va = read(dst_a); vb = read(src_a); @flag_c = va >= vb ? 1 : 0; set_nz8((va - vb) & 0x1ff); 5
      when 0x99 then dst_a = dpaddr(@x); src_a = dpaddr(@y); write(dst_a, adc(read(dst_a), read(src_a), @flag_c)); 5
      when 0xB9 then dst_a = dpaddr(@x); src_a = dpaddr(@y); write(dst_a, sbc(read(dst_a), read(src_a), @flag_c)); 5
  
      when 0xC8 then v = fetch8; @flag_c = @x >= v ? 1 : 0; set_nz8((@x - v) & 0x1ff); 2
      when 0xAD then v = fetch8; @flag_c = @y >= v ? 1 : 0; set_nz8((@y - v) & 0x1ff); 2
      when 0x3E then v = read(dpaddr(fetch8)); @flag_c = @x >= v ? 1 : 0; set_nz8((@x - v) & 0x1ff); 3
      when 0x7E then v = read(dpaddr(fetch8)); @flag_c = @y >= v ? 1 : 0; set_nz8((@y - v) & 0x1ff); 3
      when 0x1E then v = read(fetch16); @flag_c = @x >= v ? 1 : 0; set_nz8((@x - v) & 0x1ff); 4
      when 0x5E then v = read(fetch16); @flag_c = @y >= v ? 1 : 0; set_nz8((@y - v) & 0x1ff); 4
  
      when 0xBC then @a = set_nz8(@a + 1); 2
      when 0x9C then @a = set_nz8(@a - 1); 2
      when 0x3D then @x = set_nz8(@x + 1); 2
      when 0x1D then @x = set_nz8(@x - 1); 2
      when 0xFC then @y = set_nz8(@y + 1); 2
      when 0xDC then @y = set_nz8(@y - 1); 2
  
      when 0xAB then a = dpaddr(fetch8); write(a, set_nz8(read(a) + 1)); 4
      when 0x8B then a = dpaddr(fetch8); write(a, set_nz8(read(a) - 1)); 4
      when 0xBB then a = dpaddr((fetch8 + @x) & 0xff); write(a, set_nz8(read(a) + 1)); 5
      when 0x9B then a = dpaddr((fetch8 + @x) & 0xff); write(a, set_nz8(read(a) - 1)); 5
      when 0xAC then a = fetch16; write(a, set_nz8(read(a) + 1)); 5
      when 0x8C then a = fetch16; write(a, set_nz8(read(a) - 1)); 5
  
      when 0x1C then @a = do_asl(@a); 2
      when 0x0B then a = dpaddr(fetch8); write(a, do_asl(read(a))); 4
      when 0x1B then a = dpaddr((fetch8 + @x) & 0xff); write(a, do_asl(read(a))); 5
      when 0x0C then a = fetch16; write(a, do_asl(read(a))); 5
  
      when 0x5C then @a = do_lsr(@a); 2
      when 0x4B then a = dpaddr(fetch8); write(a, do_lsr(read(a))); 4
      when 0x5B then a = dpaddr((fetch8 + @x) & 0xff); write(a, do_lsr(read(a))); 5
      when 0x4C then a = fetch16; write(a, do_lsr(read(a))); 5
  
      when 0x3C then @a = do_rol(@a); 2
      when 0x2B then a = dpaddr(fetch8); write(a, do_rol(read(a))); 4
      when 0x3B then a = dpaddr((fetch8 + @x) & 0xff); write(a, do_rol(read(a))); 5
      when 0x2C then a = fetch16; write(a, do_rol(read(a))); 5
  
      when 0x7C then @a = do_ror(@a); 2
      when 0x6B then a = dpaddr(fetch8); write(a, do_ror(read(a))); 4
      when 0x7B then a = dpaddr((fetch8 + @x) & 0xff); write(a, do_ror(read(a))); 5
      when 0x6C then a = fetch16; write(a, do_ror(read(a))); 5
  
      when 0x9F then @a = set_nz8(((@a << 4) | (@a >> 4)) & 0xff); 5
  
      when 0xCF
        r = (@y & 0xff) * (@a & 0xff)
        @a = r & 0xff
        @y = (r >> 8) & 0xff
        set_nz8(@y); 9
      when 0x9E
        ya = (@y << 8) | @a
        x = @x
        if x.zero?
          @a = 0xff
          @y = 0xff
          @flag_v = 1
          @flag_h = 1
          set_nz8(@a)
          return 12
        end
        @flag_h = ((@y & 0xf) >= (x & 0xf)) ? 1 : 0
        quotient = ya / x
        remainder = ya % x
        @flag_v = quotient > 0xff ? 1 : 0
        @a = quotient & 0xff
        @y = remainder & 0xff
        set_nz8(@a); 12
  
      when 0xDF
        a = @a
        if @flag_c != 0 || a > 0x99
          a = (a + 0x60) & 0xff
          @flag_c = 1
        end
        if @flag_h != 0 || (a & 0x0f) > 9
          a = (a + 0x06) & 0xff
        end
        @a = set_nz8(a); 3
      when 0xBE
        a = @a
        if @flag_c.zero? || a > 0x99
          a = (a - 0x60) & 0xff
          @flag_c = 0
        end
        if @flag_h.zero? || (a & 0x0f) > 9
          a = (a - 0x06) & 0xff
        end
        @a = set_nz8(a); 3
  
      when 0x60 then @flag_c = 0; 2
      when 0x80 then @flag_c = 1; 2
      when 0xED then @flag_c ^= 1; 3
      when 0x20 then @flag_p = 0; 2
      when 0x40 then @flag_p = 1; 2
      when 0xE0 then @flag_v = 0; @flag_h = 0; 2
      when 0xA0 then @flag_i = 1; 3
      when 0xC0 then @flag_i = 0; 3
  
      when 0x2D then push8(@a); 4
      when 0x4D then push8(@x); 4
      when 0x6D then push8(@y); 4
      when 0x0D then push8(psw); 4
      when 0xAE then @a = pop8; 4
      when 0xCE then @x = pop8; 4
      when 0xEE then @y = pop8; 4
      when 0x8E then self.psw = pop8; 4
  
      when 0x2F then d = fetch8; s = (d & 0x80) != 0 ? d - 256 : d; @pc = (@pc + s) & 0xffff; 4
      when 0xF0 then d = fetch8; 2 + do_branch(@flag_z == 1, d)
      when 0xD0 then d = fetch8; 2 + do_branch(@flag_z.zero?, d)
      when 0xB0 then d = fetch8; 2 + do_branch(@flag_c == 1, d)
      when 0x90 then d = fetch8; 2 + do_branch(@flag_c.zero?, d)
      when 0x70 then d = fetch8; 2 + do_branch(@flag_v == 1, d)
      when 0x50 then d = fetch8; 2 + do_branch(@flag_v.zero?, d)
      when 0x30 then d = fetch8; 2 + do_branch(@flag_n == 1, d)
      when 0x10 then d = fetch8; 2 + do_branch(@flag_n.zero?, d)
  
      when 0x2E then a = dpaddr(fetch8); d = fetch8; v = read(a); 5 + do_branch(@a != v, d)
      when 0xDE then a = dpaddr((fetch8 + @x) & 0xff); d = fetch8; v = read(a); 6 + do_branch(@a != v, d)
  
      when 0xFE then d = fetch8; @y = (@y - 1) & 0xff; 4 + do_branch(@y != 0, d)
      when 0x6E then a = dpaddr(fetch8); d = fetch8; v = (read(a) - 1) & 0xff; write(a, v); 5 + do_branch(v != 0, d)
  
      when 0x5F then @pc = fetch16; 3
      when 0x1F
        base = fetch16
        ptr = (base + @x) & 0xffff
        @pc = read(ptr) | (read((ptr + 1) & 0xffff) << 8); 6
  
      when 0x3F then a = fetch16; push16(@pc); @pc = a; 8
      when 0x4F then a = 0xFF00 | fetch8; push16(@pc); @pc = a; 6
  
      when 0x01, 0x11, 0x21, 0x31, 0x41, 0x51, 0x61, 0x71,
           0x81, 0x91, 0xA1, 0xB1, 0xC1, 0xD1, 0xE1, 0xF1
        n = (op >> 4) & 0xf
        vec_addr = (0xFFDE - n * 2) & 0xffff
        target = read(vec_addr) | (read((vec_addr + 1) & 0xffff) << 8)
        push16(@pc)
        @pc = target; 8
  
      when 0x6F then @pc = pop16; 5
      when 0x7F then self.psw = pop8; @pc = pop16; 6
  
      when 0x0F
        push16(@pc)
        push8(psw)
        @flag_b = 1; @flag_i = 0
        @pc = read(0xFFDE) | (read(0xFFDF) << 8); 8
  
      when 0xEF, 0xFF then @stopped = true; 3
  
      when 0xAA
        w = fetch16; addr = w & 0x1fff; bit = (w >> 13) & 7
        v = read(addr)
        @flag_c = (v >> bit) & 1; 4
      when 0xCA
        w = fetch16; addr = w & 0x1fff; bit = (w >> 13) & 7
        v = read(addr)
        v = @flag_c != 0 ? (v | (1 << bit)) : (v & ~(1 << bit))
        write(addr, v & 0xff); 6
  
      when 0x4A then w = fetch16; addr = w & 0x1fff; bit = (w >> 13) & 7; v = (read(addr) >> bit) & 1; @flag_c &= v; 4
      when 0x6A then w = fetch16; addr = w & 0x1fff; bit = (w >> 13) & 7; v = (read(addr) >> bit) & 1; @flag_c &= (v ^ 1); 4
      when 0x0A then w = fetch16; addr = w & 0x1fff; bit = (w >> 13) & 7; v = (read(addr) >> bit) & 1; @flag_c |= v; 5
      when 0x2A then w = fetch16; addr = w & 0x1fff; bit = (w >> 13) & 7; v = (read(addr) >> bit) & 1; @flag_c |= (v ^ 1); 5
      when 0x8A then w = fetch16; addr = w & 0x1fff; bit = (w >> 13) & 7; v = (read(addr) >> bit) & 1; @flag_c ^= v; 5
  
      when 0xEA then w = fetch16; addr = w & 0x1fff; bit = (w >> 13) & 7; v = read(addr) ^ (1 << bit); write(addr, v & 0xff); 5
  
      when 0x02, 0x22, 0x42, 0x62, 0x82, 0xA2, 0xC2, 0xE2
        bit = (op >> 5) & 7
        a = dpaddr(fetch8)
        v = read(a) | (1 << bit)
        write(a, v & 0xff); 4
      when 0x12, 0x32, 0x52, 0x72, 0x92, 0xB2, 0xD2, 0xF2
        bit = (op >> 5) & 7
        a = dpaddr(fetch8)
        v = read(a) & ~(1 << bit)
        write(a, v & 0xff); 4
  
      when 0x03, 0x23, 0x43, 0x63, 0x83, 0xA3, 0xC3, 0xE3
        bit = (op >> 5) & 7
        a = dpaddr(fetch8)
        d = fetch8
        v = read(a)
        5 + do_branch(((v >> bit) & 1) == 1, d)
      when 0x13, 0x33, 0x53, 0x73, 0x93, 0xB3, 0xD3, 0xF3
        bit = (op >> 5) & 7
        a = dpaddr(fetch8)
        d = fetch8
        v = read(a)
        5 + do_branch(((v >> bit) & 1) == 0, d)
  
      when 0x0E
        a = fetch16; v = read(a)
        set_nz8((@a - v) & 0x1ff)
        write(a, v | @a); 6
      when 0x4E
        a = fetch16; v = read(a)
        set_nz8((@a - v) & 0x1ff)
        write(a, v & (~@a & 0xff)); 6
  
      else
        warn format('UNKNOWN OPCODE %02X at PC=%04X', op, (@pc - 1) & 0xffff)
        2
      end
    end
  end
